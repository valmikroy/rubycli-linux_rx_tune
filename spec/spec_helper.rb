require 'rspec'

require_relative '../bin/linux_rx_tune'

ENV['SYSFS']  = [LinuxRxTune.source_root,'spec','fixtures','sys'].join('/')
ENV['PROCFS'] = [LinuxRxTune.source_root,'spec','fixtures','proc'].join('/')

LinuxRxTune.set_kernelfs

RSpec.configure do |config|
  config.color = true
end
