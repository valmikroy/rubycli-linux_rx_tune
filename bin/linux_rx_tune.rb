#!/usr/bin/env ruby

require 'thor'
require 'logger'
require 'pathname'

module LinuxRxTune # :nodoc:
  # Singleton
  class << self
    attr_accessor :logger
    attr_accessor :verbose
    attr_accessor :cpu_topology
    attr_accessor :nic_irqs
    attr_reader :sysfs_path
    attr_reader :procfs_path

    def dry?
      ENV['DRY'] ? true : false
    end

    def default_logger
      v = LinuxRxTune.verbose
      logger = Logger.new(STDOUT)
      logger.level = Logger::INFO
      logger.level = Logger::DEBUG if v
      logger
    end

    def tty?
      $stdout.tty?
    end

    def source_root
      @source_root ||= Pathname.new(File.expand_path('../../', __FILE__))
    end

    def set_kernelfs
      @sysfs_path = ENV['SYSFS'] ? ENV['SYSFS'] : '/sys'
      @procfs_path = ENV['PROCFS'] ? ENV['PROCFS'] : '/proc'
    end
  end

  # Helpers
  module Helper
    module Topology
      #
      # Parse CPU topology
      # reading /sys/devices/system/cpu/cpu0/*
      # populates LinuxRxTune.cpu_topology for each core with
      # - its NUMA node
      # - its own sibling core
      #
      def read_cpu_topology
        # TODO: error check for existence of sysfs path
        path = [LinuxRxTune.sysfs_path, 'devices/system/cpu/'].join('/')
        Dir.foreach(path) do |cpu|
          next if cpu == '.' || cpu == '..'
          next unless matched = cpu.match(/cpu(?<cpu_number>\d{1,2})/)

          data = {
            numa_node: IO.read("#{path}/#{cpu}/topology/physical_package_id").to_i,
            siblings_hex: IO.read("#{path}/#{cpu}/topology/thread_siblings").chomp,
            siblings_str: IO.read("#{path}/#{cpu}/topology/thread_siblings_list").chomp
          }
          LinuxRxTune.cpu_topology[matched[:cpu_number].to_i] = data.clone
        end
      end

      #
      # @return [Integer]
      #   count of cpu cores
      #
      def number_of_cores
        LinuxRxTune.cpu_topology.length
      end

      #
      # @param [Integer] n
      #   Numa node either 0 or 1
      #
      # @return [Array]
      #   List of cores on given NUMA node
      #
      def get_numa_cores(n)
        t = LinuxRxTune.cpu_topology
        cores = []
        t.each_index { |i| cores.push(i) if t[i][:numa_node] == n }
        cores
      end

      # wrapper functions
      def get_numa0_cores
        get_numa_cores(0)
      end

      def get_numa1_cores
        get_numa_cores(1)
      end

      def is_numa0?(c)
        return true if get_numa0_cores.include?(c)
        false
      end

      def is_numa1?(c)
        return true if get_numa1_cores.include?(c)
        false
      end

      #
      # differentiate cores based on its NUMA affinity
      #
      def get_numa_split(cores = [])
        numa = []
        numa[0] = cores.map { |c| c if is_numa0?(c) }
        numa[1] = cores.map { |c| c if is_numa1?(c) }
        numa[0].compact!
        numa[1].compact!
        numa
      end

      def select_numa_core(numa)
        cores = []
        case numa
        when 0
          cores = get_numa0_cores
        when 1
          cores = get_numa1_cores
        when -1
          cores.push(get_numa0_cores)
          cores.push(get_numa1_cores)
          cores.flatten!
        else
          warn('NUMA node values should be 0 , 1 or -1')
        end
        cores
      end

      # CPU bitmap or hexmap is only way you can configure various kernel tuneups
      # ex.
      #   on 4 core system
      #     Zero th core will be represented as 0001
      #     First core will be represented as 0010

      #
      # Functions cores_to_bin and core_list_to_hexmap could be consider as
      # forward functions where we know which cores we want to consider in
      # human readable format and we get conversion back in various maps.
      #
      #
      # @param [Array] cores
      #   array of cores to consider [10, 30]
      #
      # @param [Integer] core_cnt
      #   total core count for creating appropriate padding, for example 40
      #
      # @return [String]
      #   with cores=[10,30], core_cnt=40 should produce string below where
      #   bit is set for specified core positions.
      #   0000000001000000000000000000010000000000
      #
      #   lowest to highest core position goes from right to left
      #
      def cores_to_bin(cores = [], core_cnt)
        c = Array.new(core_cnt, 0)
        c.each_index do |i|
          c[i] = 1 if cores.include?(i)
        end
        c.reverse.join('')
      end

      #
      # once above bitmap gets created by core positions
      # hex map can be produce below
      #
      def core_list_to_hexmap(cores = [], core_cnt)
        b = cores_to_bin(cores, core_cnt)
        h = format("%.#{core_cnt / 4}x", b.to_i(2))
        h.gsub(/^(\w{2})/, '\1,')
      end

      # Reverse functions which gives you cores in human readable format from given hexmap
      # - convert hexmap to decimal
      # - convert decimal to binary map
      # - use binary map to point enabled cores and return its array
      #
      def hex_to_dec(cpu_hexmap)
        cpu_hexmap.delete!(',').to_i(16).to_s
      end

      def dec_to_bin(c, core_cnt)
        format("%0#{core_cnt}b", c.to_i)
      end

      def dec_to_hex(c, core_cnt)
        format("%.#{core_cnt / 4}x", c.to_i)
      end

      def bin_to_cores(cpu_bitmap)
        c = cpu_bitmap.split(//)
        cores = []
        c.reverse!.each_index { |i| cores.push(i) if c[i] == '1' }
        cores
      end

      def hexmap_to_core_list(cpu_hexmap, core_cnt)
        d = hex_to_dec(cpu_hexmap)
        b = dec_to_bin(d, core_cnt)
        c = bin_to_cores(b)
        get_numa_split(c)
      end
    end

    # Affinity module holds various functions which involve in adjusting CPU topologies
    # for efficient low level network IRQ handling

    module Affinity
      #
      # - look for network card line like following in /proc/interrupts
      #   80:          0          0    1602770  ....  IR-PCI-MSI 1048586-edge      enp2s0f0-TxRx-10
      #
      # - pick up first column which is 'irq' then last \s+-TxRx-\d+ to know 'network interface name' and 'network channel'
      # - store in  LinuxRxTune.nic_irqs[iface][network_channel] =  irq
      #
      #
      # @param [String] path
      #   /proc/interrupts
      #
      def scan_proc_interrupts(path = [LinuxRxTune.procfs_path, 'interrupts'].join('/'))
        File.readlines(path).each do |l|
          l.chomp!
          next unless m = l.match(/^\s+?(?<irq>\d+?):.*?(?<iface>enp\ds\d\w\d).+?(?<ch>\d+)$/)
          data = {
            interface: m[:iface],
            channel: m[:ch]
          }
          LinuxRxTune.nic_irqs[m[:iface]] = [] if LinuxRxTune.nic_irqs[m[:iface]].nil?
          LinuxRxTune.nic_irqs[m[:iface]][m[:ch].to_i] = m[:irq].to_i
        end
      end

      #
      # Get list of network interfaces based on scanning of /proc/interrupts
      #
      # @return[Array]
      #   ex: [ enp2s0f0 , enp2s0f1 ]
      #
      def get_ifaces
        LinuxRxTune.nic_irqs.keys
      end

      #
      #
      # @param [String] iface
      #   Provide name of network interface
      #
      # @return [Hash]
      #   Returns key value pair of network channel to irq mapping
      #
      def get_network_irqs(iface)
        LinuxRxTune.nic_irqs[iface]
      end


      #
      # @param [Integer] irq
      #   IRQ number
      #
      # @return [String]
      #   Returns CPU map to which given IRQ has been tied by reading /proc/<IRQ>/smp_affinity
      #
      def get_irq_cpu_map(irq)
        IO.read([LinuxRxTune.procfs_path, 'irq', irq, 'smp_affinity'].join('/')).chomp!
      end

      def get_xps_cpu_map(iface,net_ch)
        IO.read([LinuxRxTune.sysfs_path, 'class/net', iface, 'queues', "tx-#{net_ch}", 'xps_cpus'].join('/')).chomp!
      end
    end

    # include Affinity
    # include Topology
  end

  module RSS
    include Helper

    # Print affinity map
    #
    # <network iface> <network channel> <IRQ>  <NUMA0 CPU core>   <NUMA1 CPU core>
    #

    def show_rss_affinity
      report = []
      nic_irqs = LinuxRxTune.nic_irqs

      report.push(format("%10s\t%3s\t%4s\t%20s\t%20s", 'iface', 'ch', 'irq', 'numa0', 'numa1'))

      nic_irqs.each do |iface, _v|
        nic_irqs[iface].each_index do |net_ch|
          irq = nic_irqs[iface][net_ch]
          cpu_map = get_irq_cpu_map(irq)
          c = hexmap_to_core_list(cpu_map, number_of_cores)

          report.push(format("%10s\t%3d\t%4d\t%20s\t%20s", iface, net_ch, irq,
                             c[0].empty? ? '-' : c[0].join(','),
                             c[1].empty? ? '-' : c[1].join(',')))
        end
      end
      # IO.write("/Users/abhsawan/report.out" ,report.join("\n"))
      report.join("\n")
    end

    #
    # This creates hexmap of given CPU cores to update /proc/IRQ/smp_affinity for specific network channel
    #
    # @param [Array] cores
    #   CPU cores
    #
    # @param [Array] irqs
    #   List of IRQs
    #
    # @param [Integer] core_cnt
    #   CPU Core count number, this is only for reference to create hexmap with appropriate padding
    #
    # number of irqs and available cores to serve those irqs will not be the same and more likely
    # core count will be lesser than network IRQs.
    # This asymmetry can be managed by create wrapping effect using IRQ and core counts
    #
    # @return [Hash] data
    #  data['/proc/irq/<IRQ>/smp_affinity'] = [<cpu_hexmap>,[<numeric core array>]]
    #
    def assign_rss_affinity(cores = [], irqs = [], core_cnt)
      data = {}
      cidx = 0
      irqs.each_index do |i|
        cidx = 0 if cidx == cores.length
        hex = core_list_to_hexmap([cores[cidx]], core_cnt)
        data["/proc/irq/#{irqs[i]}/smp_affinity"] = [hex, [cores[cidx]]]
        cidx += 1
      end
      data
    end

    # Creates affinity map based on selecting cores from given NUMA node.
    #
    # This assign single core per individual irq
    #
    # @param [Integer] numa
    #   numa node number ( ex. 0 or 1 )
    #   this can be -1 which will consider cores from both numa 0 and 1
    #
    def enable_rss_numa_per_core(numa)
      data = {}
      cores = select_numa_core(numa)
      get_ifaces.each do |i|
        data[i] = assign_rss_affinity(cores, get_network_irqs(i), number_of_cores)
      end
      data
    end

    # Create affinity map on selecting cores from given NUMA node
    #
    # But unlike enable_rss_numa_per_core
    # This assign all cores to individual irq
    #
    def enable_rss_numa_all_cores(numa)
      data = {}
      cores = select_numa_core(numa)
      hex = core_list_to_hexmap(cores, number_of_cores)
      get_ifaces.each do |i|
        irqs = get_network_irqs(i)
        data[i] = {}
        irqs.each do |irq|
          data[i]["/proc/irq/#{irq}/smp_affinity"] = [hex, cores]
        end
      end
      data
    end
  end

  module XPS
    include Helper

    # Print affinity map
    #
    # <network iface> <network channel> <IRQ>  <NUMA0 CPU core>   <NUMA1 CPU core>
    #

    def show_xps_affinity
      report = []

      nic_irqs = LinuxRxTune.nic_irqs

      report.push(format("%10s\t%3s\t%20s\t%20s", 'iface', 'ch',  'numa0', 'numa1'))

      nic_irqs.each do |iface, _v|
        nic_irqs[iface].each_index do |net_ch|
          irq = nic_irqs[iface][net_ch]
          cpu_map = get_xps_cpu_map(iface,net_ch)
          c = hexmap_to_core_list(cpu_map, number_of_cores)

          report.push(format("%10s\t%3d\t%20s\t%20s", iface, net_ch,
                             c[0].empty? ? '-' : c[0].join(','),
                             c[1].empty? ? '-' : c[1].join(',')))
        end
      end
      #IO.write("/Users/abhsawan/report.out" ,report.join("\n"))
      report.join("\n")
    end



    def assign_xps_affinity(cores = [], iface, core_cnt)
      data = {}
      cidx = 0
      network_ch_cnt = get_network_irqs(iface).length
      (0...network_ch_cnt).each do |c|
        cidx = 0 if cidx == cores.length
        hex = core_list_to_hexmap([cores[cidx]], core_cnt)
        data["/sys/class/net/#{iface}/queues/tx-#{c}/xps_cpus"] = [hex, [cores[cidx]]]
        cidx += 1
      end
      data
    end

    def enable_xps_numa_per_core(numa)
      data = {}
      cores = select_numa_core(numa)
      get_ifaces.each do |iface|
        data[iface] = assign_xps_affinity(cores, iface, number_of_cores)
      end
      data
    end

    def enable_xps_numa_all_cores(numa)
      data = {}
      cores = select_numa_core(numa)
      hex = core_list_to_hexmap(cores, number_of_cores)
      get_ifaces.each do |iface|
        network_ch_cnt = get_network_irqs(iface).length
        data[iface] = {}
        (0...network_ch_cnt).each do |c|
          data[iface]["/sys/class/net/#{iface}/queues/tx-#{c}/xps_cpus"] = [hex, cores]
        end
      end
      data
    end
  end

  # CLI
  class CLI < Thor
    include LinuxRxTune::Helper::Topology
    include LinuxRxTune::Helper::Affinity
    include LinuxRxTune::RSS
    include LinuxRxTune::XPS

    def self.global_options
      method_option :verbose,
                    aliases: ['-v', '--verbose'],
                    desc: 'Verbose',
                    type: :boolean,
                    default: false
    end

    def self.core_options
      method_option :numa,
                    aliases: ['-n', '--numa'],
                    desc: 'Numa to configure',
                    type: :numeric,
                    default: 0
      method_option :all_cores,
                    aliases: ['-a', '--all_cores'],
                    desc: 'Consider all cores on given numa',
                    type: :boolean,
                    default: false
    end

    # enable_rss --numa 0 --per_core (disable irq balance)
    # enable_rss --numa 0 --entire_numa
    # enable_xps /disable
    # enable_rps /disable
    # enable_rfs /disable
    # setup_budget /restore budget
    # cpu_topology give output for mapping of each ring to CPU core hex , binary and decimal
    #
    # have a conversion function which can convert binary string to hex and back for CPU affinity
    #
    #
    #
    #

    desc 'show_rss', 'Show existing RSS settings'
    global_options
    def show_rss
      scan_proc_interrupts
      read_cpu_topology
      puts show_rss_affinity
    end

    desc 'set_rss', 'Set RSS for existing channels'
    global_options
    core_options
    def set_rss
      scan_proc_interrupts
      read_cpu_topology

      data = if options[:all_cores]
               enable_rss_numa_all_cores(options[:numa])
             else
               enable_rss_numa_per_core(options[:numa])
             end

      data.each do |iface, irq_info|
        puts "# setting up first NIC #{iface}"
        irq_info.each do |smp_affinity, cpu_maps|
          puts
          puts "echo setting up #{iface} to cores #{cpu_maps[1].join(',')}  ,  #{cpu_maps[0]}   #{smp_affinity}  "
          puts "echo #{cpu_maps[0]} >  #{smp_affinity} "
        end
      end
    end

    desc 'show_xps', 'Show existing XPS settings'
    global_options
    def show_xps
      scan_proc_interrupts
      read_cpu_topology
      puts show_xps_affinity
    end

    desc 'set_xps', 'Set XPS for TX queues'
    global_options
    core_options
    def set_xps
      scan_proc_interrupts
      read_cpu_topology
      data = if options[:all_cores]
               enable_xps_numa_all_cores(options[:numa])
             else
               enable_xps_numa_per_core(options[:numa])
             end

      data.each do |iface, tx_info|
        puts "# setting up first NIC #{iface}"
        tx_info.each do |xps_affinity, cpu_maps|
          puts
          puts "echo setting up #{iface} to cores #{cpu_maps[1].join(',')}  ,  #{cpu_maps[0]}   #{xps_affinity}  "
          puts "echo #{cpu_maps[0]} >  #{xps_affinity} "
        end
      end
    end
  end
end

LinuxRxTune.verbose = ENV['VERBOSE'] ? true : false
LinuxRxTune.logger = LinuxRxTune.default_logger
LinuxRxTune.set_kernelfs

LinuxRxTune.cpu_topology = []
LinuxRxTune.nic_irqs = {}

# check if its linux
# check for directory  /sys/devices/system/cpu/cpu\d{1,2}
# determine NUMA node by reading topology/physical_package_id
# determine siblings hex hash topology/thread_siblings and topology/thread_siblings_list
#
# parse /proc/interrupts
# determine number of ring buffer channels
# determine their respective irqs
# assign only NUMA0 cpu cores in to /proc/irq/<irq no>/smp_affinity for network queues

LinuxRxTune::CLI.start(ARGV) if $PROGRAM_NAME == __FILE__
