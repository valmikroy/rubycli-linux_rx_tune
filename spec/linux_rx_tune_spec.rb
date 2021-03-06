require 'spec_helper'

include LinuxRxTune::Helper::Topology
include LinuxRxTune::Helper::Affinity

describe '#set_kernelfs' do
  it 'get updated kernel fs paths for testing' do
    expect(LinuxRxTune.procfs_path).to match('fixtures/proc')
    expect(LinuxRxTune.sysfs_path).to match('fixtures/sys')
  end
end

describe '#read_cpu' do
  it 'read_cpu_topology' do
    read_cpu_topology
    expect(LinuxRxTune.cpu_topology[16]).to eq(numa_node: 1, siblings_hex: '10,00010000', siblings_str: '16,36')
  end
end

describe '#numa cores' do
  it 'cores' do
    LinuxRxTune.cpu_topology = []
    read_cpu_topology
    expect(get_numa0_cores).to eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29])
    expect(get_numa1_cores).to eq([10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39])
    expect(get_numa_split([8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])).to eq([[8, 9, 20], [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]])
    expect(get_numa_split([10, 11, 12, 13, 14, 15, 16, 17, 18, 19])).to eq([[], [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]])
  end
end

describe '#conversions' do
  it 'bitmap and hexmap conversion' do
    expect(hex_to_dec('00,20000200')).to eq('536871424')
    expect(dec_to_bin('536871424', 40)).to eq('0000000000100000000000000000001000000000')
    expect(dec_to_hex('536871424', 40)).to eq('0020000200')
    expect(bin_to_cores('0000000000000000000000000000000000000001')).to eq([0])
    expect(bin_to_cores('0000000000100000000000000000001000000000')).to eq([9, 29])
    expect(bin_to_cores('1111111111111111111111111111111111111111')).to eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39])
    expect(cores_to_bin([10, 30], 40)).to eq('0000000001000000000000000000010000000000')
    expect(core_list_to_hexmap([10, 30], 40)).to eq('00,40000400')
    expect(core_list_to_hexmap([1, 38], 40)).to eq('40,00000002')
    expect(hexmap_to_core_list('00,00000001', 40)).to eq([[0], []])
  end
end

describe 'RSS report' do
  include LinuxRxTune::RSS
  before(:each) do
    LinuxRxTune.nic_irqs = {}
    scan_proc_interrupts([LinuxRxTune.source_root, 'spec', 'fixtures', 'proc_interrupts_10G.txt'].join('/'))
    LinuxRxTune.cpu_topology = []
    read_cpu_topology
  end
  it 'report' do
    expect(show_rss_affinity).to eq(IO.read([LinuxRxTune.source_root, 'spec', 'fixtures', 'report_rss_affinity.txt'].join('/')))
  end
end

describe 'XPS report' do
  include LinuxRxTune::XPS
  before(:each) do
    LinuxRxTune.nic_irqs = {}
    scan_proc_interrupts([LinuxRxTune.source_root, 'spec', 'fixtures', 'proc_interrupts_10G.txt'].join('/'))
    LinuxRxTune.cpu_topology = []
    read_cpu_topology
  end
  it 'report' do
    expect(show_xps_affinity).to eq(IO.read([LinuxRxTune.source_root, 'spec', 'fixtures', 'report_xps_affinity.txt'].join('/')))
  end
end

describe 'enable rss' do
  include LinuxRxTune::RSS
  before(:each) do
    LinuxRxTune.nic_irqs = {}
    scan_proc_interrupts([LinuxRxTune.source_root, 'spec', 'fixtures', 'proc_interrupts_10G.txt'].join('/'))
    LinuxRxTune.cpu_topology = []
    read_cpu_topology
  end

  it 'should be core from numa0' do
    data = enable_rss_numa_per_core(0)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['00,00200000', [21]])
    expect(data['enp2s0f1']['/proc/irq/116/smp_affinity']).to eq(['00,00000010', [4]])
  end
  it 'should be core from numa1' do
    data = enable_rss_numa_per_core(1)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['00,80000000', [31]])
    expect(data['enp2s0f1']['/proc/irq/116/smp_affinity']).to eq(['00,00004000', [14]])
  end

  it 'should be core from numa 0 & 1' do
    data = enable_rss_numa_per_core(-1)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['00,80000000', [31]])
    expect(data['enp2s0f1']['/proc/irq/116/smp_affinity']).to eq(['00,00000010', [4]])
  end

  it 'should be all cores from numa0' do
    data = enable_rss_numa_all_cores(0)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['00,3ff003ff', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]])
  end

  it 'should be all cores from numa1' do
    data = enable_rss_numa_all_cores(1)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['ff,c00ffc00', [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39]])
  end

  it 'should be all cores from numa 0 & 1' do
    data = enable_rss_numa_all_cores(-1)
    expect(data['enp2s0f0']['/proc/irq/101/smp_affinity']).to eq(['ff,ffffffff', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39]])
  end
end

describe 'enable xps' do
  include LinuxRxTune::XPS
  before(:each) do
    LinuxRxTune.cpu_topology = []
    read_cpu_topology
  end

  it 'should be core from numa0' do
    data = enable_xps_numa_per_core(0)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['00,00000001', [0]])
    expect(data['enp2s0f1']['/sys/class/net/enp2s0f1/queues/tx-0/xps_cpus']).to eq(['00,00000001', [0]])
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-11/xps_cpus']).to eq(['00,00200000', [21]])
    expect(data['enp2s0f1']['/sys/class/net/enp2s0f1/queues/tx-30/xps_cpus']).to eq(['00,00100000', [20]])
  end

  it 'should be core from numa1' do
    data = enable_xps_numa_per_core(1)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['00,00000400', [10]])
    expect(data['enp2s0f1']['/sys/class/net/enp2s0f1/queues/tx-0/xps_cpus']).to eq(['00,00000400', [10]])
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-11/xps_cpus']).to eq(['00,80000000', [31]])
    expect(data['enp2s0f1']['/sys/class/net/enp2s0f1/queues/tx-30/xps_cpus']).to eq(['00,40000000', [30]])
  end

  it 'should be core from numa 0 & 1' do
    data = enable_xps_numa_per_core(-1)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['00,00000001', [0]])
    expect(data['enp2s0f1']['/sys/class/net/enp2s0f1/queues/tx-30/xps_cpus']).to eq(['00,40000000', [30]])
  end

  it 'should be all cores from numa0' do
    data = enable_xps_numa_all_cores(0)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['00,3ff003ff', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]])
  end

  it 'should be all cores from numa1' do
    data = enable_xps_numa_all_cores(1)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['ff,c00ffc00', [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39]])
  end

  it 'should be all cores from numa 0 & 1' do
    data = enable_xps_numa_all_cores(-1)
    expect(data['enp2s0f0']['/sys/class/net/enp2s0f0/queues/tx-0/xps_cpus']).to eq(['ff,ffffffff', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39]])
  end
end

describe '#get_network_irq' do
  context '10G' do
    before do
      LinuxRxTune.nic_irqs = {}
      scan_proc_interrupts([LinuxRxTune.source_root, 'spec', 'fixtures', 'proc_interrupts_10G.txt'].join('/'))
    end

    it '10G' do
      expect(LinuxRxTune.nic_irqs.keys.length).to eq(2)
      expect(LinuxRxTune.nic_irqs['enp2s0f0'].length).to eq(40)
      expect(LinuxRxTune.nic_irqs['enp2s0f1'].length).to eq(40)
      expect(get_ifaces).to eq(%w[enp2s0f0 enp2s0f1])
      expect(get_network_irqs('enp2s0f0')[39]).to eq(109)
      expect(get_network_irqs('enp2s0f1')[39]).to eq(151)
    end
  end

  context '25G' do
    before do
      LinuxRxTune.nic_irqs = {}
      scan_proc_interrupts([LinuxRxTune.source_root, 'spec', 'fixtures', 'proc_interrupts_25g.txt'].join('/'))
    end

    it '25G' do
      expect(LinuxRxTune.nic_irqs.keys.length).to eq(2)
      expect(LinuxRxTune.nic_irqs['enp2s0f0'].length).to eq(32)
      expect(LinuxRxTune.nic_irqs['enp2s0f1'].length).to eq(32)
      expect(get_ifaces).to eq(%w[enp2s0f0 enp2s0f1])
      expect(get_network_irqs('enp2s0f0')[31]).to eq(70)
      expect(get_network_irqs('enp2s0f1')[31]).to eq(109)
    end
  end
end
