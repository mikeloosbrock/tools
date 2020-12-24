#!/usr/bin/env ruby

require 'optparse'

def main
  begin
    opts = {}
    op = OptionParser.new
    op.banner =
      "Usage:\n" +
      "  #{File.basename $0} [options]\n" +
      "Options:"
    op.summary_indent = '  '; op.summary_width = 9
    op.on("-g REGEX", "IOMMU group filter.") { |v| opts[:g] = v } 
    op.on("-a REGEX", "PCI address filter. Address format is 'DOMAIN:BUS:DEVICE.FUNCTION', each field in hex.") { |v| opts[:a] = v }
    op.on("-d REGEX", "PCI description filter.") { |v| opts[:d] = v }
    op.on("-k",       "Display host kernel parameters for controlling VFIO.") { opts[:k] = true }
    op.on("-v",       "Display virt-install CLI options for creating the Guest VM.") { opts[:v] = true }
    op.on("-l",       "Display libvirt XML configuration for the Guest VM (Domain).") { opts[:l] = true }
    op.on("-q",       "Display qemu CLI options for running the Guest VM.") { opts[:q] = true }
    op.on("-h",       "Display this help message and exit.") { puts op.help; exit 0 }
    op.parse!
  rescue => e
    raise "Error: Invalid command line options or arguments specified => #{e}"
  end
  addr_groups = {}; iommu_dir = '/sys/kernel/iommu_groups'
  Dir.entries(iommu_dir).each do |group|
    next if group !~ /^\d+$/
    Dir.entries("#{iommu_dir}/#{group}/devices").each do |addr|
      addr_groups[addr] = group
    end
  end
  devices = []; device = nil
  `lspci -Dnnvv`.each_line do |line|
    case line.rstrip!
      when /^((....):(..):(..)\.(..?)) (.*\[(....:....)\].*)$/
        devices << device if device
        device = { addr: $1, dom: $2, bus: $3, dev: $4, fun: $5, desc: $6, id: $7 }
        device[:lines] = [line]
        device[:group] = addr_groups[device[:addr]]
        device = nil if opts[:g] and device[:group] !~ /#{opts[:g]}/
        device = nil if opts[:a] and device[:addr]  !~ /#{opts[:a]}/
        device = nil if opts[:d] and device[:desc]  !~ /#{opts[:d]}/
      else
        device[:lines] << line if device
    end
  end
  devices << device if device
  devices.each do |device|
    puts "#{device[:lines].join "\n"}"
    puts "#{' '*8}IOMMU Group: #{device[:group]}"
    puts "#{' '*8}VFIO ID: #{device[:id]}\n "
  end
  div = '#' + '=' * 79
  if opts[:k]
    ids = devices.map { |device| device[:id] }
    puts "#{div}\n# Host kernel parameters for controlling VFIO.\n#{div}"
    puts "=> vfio-pci.ids=#{ids.join ','}"
    puts "- If passing all GPUs through on a headless KVM host, use this: video=vesafb:off,efifb:off vfio-pci.ids=#{ids.join ','}"
    puts "- If Ubuntu, add the above to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub."
    puts ""
  end
  if opts[:v]
    puts "#{div}\n# virt-install CLI options for creating the Guest VM. \n#{div}"
    devices.each do |device|
      puts "--hostdev pci_#{device[:dom]}_#{device[:bus]}_#{device[:dev]}_#{device[:fun]}"
    end
  end
  if opts[:l]
    puts "#{div}\n# libvirt XML configuration for the Guest VM (Domain).\n#{div}"
    puts "  <devices>"
    devices.each do |device|
      d = {}; [:dom,:bus,:dev,:fun].each { |k| d[k] = '0x' + device[k] }
      puts "    <hostdev mode='subsystem' type='pci' managed='yes'>"
      puts "      <source>"
      puts "        <address domain='#{d[:dom]}' bus='#{d[:bus]}' slot='#{d[:dev]}' function='#{d[:fun]}' />"
      puts "     </source>"
      puts "    </hostdev>"
    end
    puts "  </devices>"
    puts ""
  end
  if opts[:q]
    puts "#{div}\n# qemu CLI options for running the Guest VM.\n#{div}"
    puts "- TODO"
  end
end
main if $0 == __FILE__
