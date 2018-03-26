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
     @sysfs_path = ENV['SYSFS'] ?   ENV['SYSFS'] : '/sys'
     @procfs_path = ENV['PROCFS'] ? ENV['PROCFS'] : '/proc'
    end


  end

  # Helpers
  module Helper

    module Topology


      def hex_to_dec(cpu_hexmap)
        cpu_hexmap.gsub!(/,/,'').to_i(16).to_s
      end

      def dec_to_bin(c,core_cnt)
        sprintf("%0#{core_cnt}b",c.to_i)
      end

      def dec_to_hex(c,core_cnt)
        sprintf("%.#{core_cnt/4}x",c.to_i)
      end

      def bin_to_cores(cpu_bitmap)
          c = cpu_bitmap.split(//)
          cores = []
          c.reverse.each_index {|i| cores.push(i) if c[i] == "1"  }
          return cores
      end



      def get_numa_split(cores=[])
        numa = []
        numa[0] = cores.map {|c| c if is_numa0?(c) }
        numa[1] = cores.map {|c| c if is_numa1?(c) }
        numa[0].compact!
        numa[1].compact!
        return numa
      end

      def hexmap_to_core_list(cpu_hexmap,core_cnt)
        d = hex_to_dec(cpu_hexmap)
        b = dec_to_bin(d,core_cnt)
        c = bin_to_cores(b)
        return get_numa_split(c)
      end


      def cores_to_bin(cores=[],core_cnt)
        c = Array.new(core_cnt,0)
        c.each_index do |i|
          c[i] = 1 if  cores.include?(i)
        end
        return c.reverse.join('')
      end


      def core_list_to_hexmap(cores=[],core_cnt)
       b = cores_to_bin(cores,core_cnt)
       return sprintf("%.#{core_cnt/4}x",b.to_i(2))
      end




      def read_cpu_topology
        #TODO error check for existence of sysfs path
        path = [ LinuxRxTune.sysfs_path, 'devices/system/cpu/' ].join('/')
        Dir.foreach(path) do |cpu|
          next if  cpu == '.'  || cpu == '..'
          next unless matched = cpu.match(/cpu(?<cpu_number>\d{1,2})/)

          data = {
            :numa_node => IO.read("#{path}/#{cpu}/topology/physical_package_id").to_i,
            :siblings_hex => IO.read("#{path}/#{cpu}/topology/thread_siblings").chomp,
            :siblings_str => IO.read("#{path}/#{cpu}/topology/thread_siblings_list").chomp
          }
          LinuxRxTune.cpu_topology[matched[:cpu_number].to_i] = data.clone
        end
      end

      def number_of_cores
        LinuxRxTune.cpu_topology.length
      end

      def get_numa_cores(n)
        t = LinuxRxTune.cpu_topology
        cores = []
        t.each_index { |i|  cores.push(i) if t[i][:numa_node] == n }
        return cores
      end


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





      #####
      def get_numa0_hex
        LinuxRxTune.cpu_topology.select { |i|  i[:numa_node] == 0 }.map{ |j| j[:siblings_hex] }
      end

      def get_numa0_str
        LinuxRxTune.cpu_topology.select { |i|  i[:numa_node] == 0 }.map{ |j| j[:siblings_str] }
      end

      def get_numa1_hex
        LinuxRxTune.cpu_topology.select { |i|  i[:numa_node] == 1 }.map{ |j| j[:siblings_hex] }
      end

      def get_numa1_str
        LinuxRxTune.cpu_topology.select { |i|  i[:numa_node] == 1 }.map{ |j| j[:siblings_str] }
      end

      def get_core_cnt
        LinuxRxTune.cpu_topology.length
      end

    end


    module Affinity


      # Scanning /proc/interrupts
      # Get existing irqs tied to network interface
      def scan_proc_interrupts(path = [LinuxRxTune.procfs_path,'interrupts'].join('/'))
        File.readlines(path).each do |l|
          l.chomp!
          next  unless m = l.match(/^\s+?(?<irq>\d+?):.*?(?<iface>enp2s\d\w\d).+?(?<ch>\d+)$/)
          data = {
             :interface => m[:iface],
             :channel  => m[:ch]
          }
          LinuxRxTune.nic_irqs[m[:iface]] = [] if LinuxRxTune.nic_irqs[m[:iface]].nil?
          LinuxRxTune.nic_irqs[m[:iface]][m[:ch].to_i] = m[:irq].to_i
        end
      end


      def get_ifaces
        LinuxRxTune.nic_irqs.keys
      end

      def get_network_irqs(iface)
        LinuxRxTune.nic_irqs[iface]
      end

      def get_irq_cpu_map(irq)
        IO.read( [LinuxRxTune.procfs_path, 'irq', irq, 'smp_affinity' ].join('/') ).chomp!
      end

    end


    include Affinity
    include Topology


    def show_net_affinity
      scan_proc_interrupts
      read_cpu_topology

      report = []

      nic_irqs =  LinuxRxTune.nic_irqs


      report.push(sprintf("%10s\t%3s\t%4s\t%20s\t%20s",'iface','ch','irq','numa0','numa1' ))
      nic_irqs.each do |iface,_v|
       nic_irqs[iface].each_index  do |net_ch|
         irq = nic_irqs[iface][net_ch]
         cpu_map = get_irq_cpu_map(irq)
         c = hexmap_to_core_list(cpu_map,number_of_cores)

         report.push(sprintf("%10s\t%3d\t%4d\t%20s\t%20s",iface,net_ch,irq,
                             c[0].length == 0 ? "-" : c[0].join(","),
                             c[1].length == 0 ? "-" :c[1].join(",")))
       end
      end
      report.join("\n")
    end


    def assign_affinity(cores=[],irqs=[],core_cnt)
      data = {}
        cidx = 0
        irqs.each_index do |i|
          cidx = 0 if cidx == cores.length
          hex = core_list_to_hexmap([ cores[cidx] ],core_cnt)
          data["/proc/irq/#{irqs[i]}/smp_affinity"] = [ hex , cores[cidx] ]
          cidx+=1
        end
      data
    end


    def enable_rss_numa_per_core(numa)
      data = {}
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
          warn("NUMA node values should be 0 , 1 or -1")
      end


      get_ifaces.each do |i|
        data[i] = assign_affinity(cores,get_network_irqs(i),number_of_cores)
      end
      data
    end

    def enable_rss_numa_all_cores(numa)
      data = {}
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
          warn("NUMA node values should be 0 , 1 or -1")
      end
      hex = core_list_to_hexmap(cores,number_of_cores)
      get_ifaces.each do |i|
        irqs = get_network_irqs(i)
        data[i] = {}
        irqs.each do |irq|
          data[i]["/proc/irq/#{irq}/smp_affinity"] = [ hex, cores ]
        end
      end
      data
    end





    def enable_rps_numa0
      data = {}
      numa0_cores_hex = get_numa0_hex
      numa0_cores_str = get_numa0_str
      get_ifaces.each do |i|
        irqs = LinuxRxTune.nic_irqs[i]
        cidx = 0
        irqs.each_index  do |idx|
          cidx = 0 if cidx == numa0_cores_hex.length
          data["/sys/class/net/#{i}/queues/rx-#{idx}/rps_cpus"] = [ numa0_cores_hex[cidx], numa0_cores_str[cidx] ]
          cidx+=1
        end
      end
      data
    end

    def enable_xps_numa0
      data = {}
      numa0_cores_hex = get_numa0_hex
      numa0_cores_str = get_numa0_str
      get_ifaces.each do |i|
        irqs = LinuxRxTune.nic_irqs[i]
        cidx = 0
        irqs.each_index  do |idx|
          cidx = 0 if cidx == numa0_cores_hex.length
          data["/sys/class/net/#{i}/queues/tx-#{idx}/xps_cpus"] = [ numa0_cores_hex[cidx] , numa0_cores_str[cidx] ]
          cidx+=1
        end
      end
      data
    end

    def enable_xps_numa1
      data = {}
      numa1_cores_hex = get_numa1_hex
      numa1_cores_str = get_numa1_str
      get_ifaces.each do |i|
        irqs = LinuxRxTune.nic_irqs[i]
        cidx = 0
        irqs.each_index  do |idx|
          cidx = 0 if cidx == numa1_cores_hex.length
          data["/sys/class/net/#{i}/queues/tx-#{idx}/xps_cpus"] = [ numa1_cores_hex[cidx] , numa1_cores_str[cidx] ]
          cidx+=1
        end
      end
      data
    end



    def func1(j)
      LinuxRxTune.logger.info("Default logging test - #{j}")
      LinuxRxTune.logger.debug("debug/verbose logging test - #{j}")
      func2(j) + 2
    end

    def func2(i)
      LinuxRxTune.logger.info("Default logging test - #{i}")
      LinuxRxTune.logger.debug("debug/verbose logging test - #{i}")
      i + 1
    end

    def start
      puts func1(4)
      puts func2(5)
    end

  end

  # CLI
  class CLI < Thor
    include Helper

    def self.global_options
      method_option :verbose,
                    aliases: ['-v', '--verbose'],
                    desc: 'Verbose',
                    type: :boolean,
                    default: false
    end


    def self.core_options
      method_option :numa,
                    aliases: ['-n','--numa'],
                    desc: 'Numa to configure',
                    type: :numeric,
                    default: 0
      method_option :all_cores,
                    aliases: ['-a','--all_cores'],
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
     puts show_net_affinity
    end

    desc 'set_rss', 'Set RSS for existing channels'
    global_options
    core_options
    def set_rss
      # all cores on single NUMA
      #

      if options[:all_cores]
        data = enable_rss_numa_all_cores(options[:numa])
      else
        data = enable_rss_numa_per_core(options[:numa])
      end

      data.each do | iface, irq_info|
        puts "# setting up first NIC #{iface}"
        irq_info.each do |smp_affinity, cpu_maps|
          puts "# setting up #{iface} to cores #{cpu_maps[1].join(',')} "
          puts "#{smp_affinity} > #{cpu_maps[0]}"
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
