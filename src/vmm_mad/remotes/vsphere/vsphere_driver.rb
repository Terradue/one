# ---------------------------------------------------------------------------- #
# Copyright 2010-2011, C12G Labs S.L                                           #
#                                                                              #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

require "scripts_common"
require 'yaml'
require "CommandManager"
require 'OpenNebula'

include OpenNebula

class VMware2Driver
  # -------------------------------------------------------------------------#
  # Set up the environment for the driver                                    #
  # -------------------------------------------------------------------------#
  ONE_LOCATION = ENV["ONE_LOCATION"]

  if !ONE_LOCATION
    BIN_LOCATION = "/usr/bin"
    LIB_LOCATION = "/usr/lib/one"
    ETC_LOCATION = "/etc/one/"
    VAR_LOCATION = "/var/lib/one"
  else
    LIB_LOCATION = ONE_LOCATION + "/lib"
    BIN_LOCATION = ONE_LOCATION + "/bin"
    ETC_LOCATION = ONE_LOCATION  + "/etc/"
    VAR_LOCATION = ONE_LOCATION + "/var/"
  end

  CONF_FILE   = ETC_LOCATION + "/vmwarerc"
  CHECKPOINT  = VAR_LOCATION + "/remotes/vmm/vmware2/checkpoint"

  ENV['LANG'] = 'C'

  SHUTDOWN_INTERVAL = 5
  SHUTDOWN_TIMEOUT  = 500

  BOOT_INTERVAL = 10
  BOOT_TIMEOUT = 1200

  def initialize(host)
    conf  = YAML::load(File.read(CONF_FILE))

    @uri  = conf[:libvirt_uri].gsub!('@HOST@', host)
    @host = host

    @user = conf[:username]
    @pass = conf[:password]

    @datacenter = conf[:datacenter]
    @vcenter    = conf[:vcenter]

    begin
      @client = Client.new()
    rescue Exception => e
      puts "Error: #{e}"
      exit -1
    end

  end

  # ######################################################################## #
  #                       VMWARE DRIVER ACTIONS                              #
  # ######################################################################## #

  # ------------------------------------------------------------------------ #
  # Deploy & define a VM based on its description file                       #
  # ------------------------------------------------------------------------ #
  def deploy(dfile, id)
    # Define the domain if it is not already defined (e.g. from UNKNOWN)

    if not domain_defined?(id)
      deploy_id = define_domain(dfile)

      exit -1 if deploy_id.nil?
    else
      deploy_id = "one-#{id}"
    end

    OpenNebula.log_debug("Successfully defined domain #{deploy_id}.")

    # Start the VM
    rc, info = do_action("virsh -c #{@uri} start #{deploy_id}")
    sleep BOOT_INTERVAL

    counter = 0
    
    begin

      sleep BOOT_INTERVAL
      info = `/usr/lib/vmware-vcli/apps/vm/vminfo.pl --username #{@user} --password #{@pass} --server #{@host} --vmname #{deploy_id} | grep Cpu`
      info = "@Not Known" if $? == false
      counter = counter + BOOT_INTERVAL
    end while info.match(".*Not Known.*") and counter < BOOT_TIMEOUT

    if counter >= BOOT_TIMEOUT
      OpenNebula.error_message(
      "Timeout reached, Check if VM is booted")
      undefine_domain(deploy_id)
      exit info
    end

    return deploy_id
  end

  # ------------------------------------------------------------------------ #
  # Cancels & undefine the VM                                                #
  # ------------------------------------------------------------------------ #
  def cancel(deploy_id)
    # Destroy the VM
    rc, info = do_action("virsh -c #{@uri} destroy #{deploy_id}")

    exit info if rc == false

    counter = 0
    
    begin
      rc, info = do_action("virsh -c #{@uri} list")
      info     = "" if rc == false

      sleep SHUTDOWN_INTERVAL

      counter = counter + SHUTDOWN_INTERVAL
    end while info.match(deploy_id) and counter < SHUTDOWN_TIMEOUT

    if counter >= SHUTDOWN_TIMEOUT
      OpenNebula.error_message(
      "Timeout reached, VM #{deploy_id} is still alive")
      exit - 1
    end

    OpenNebula.log_debug("Successfully canceled domain #{deploy_id}.")

    # Undefine the VM
    undefine_domain(deploy_id)
  end

  # ------------------------------------------------------------------------ #
  # Reboots a running VM                                                     #
  # ------------------------------------------------------------------------ #
  def reboot(deploy_id)
    rc, info = do_action("virsh -c #{@uri} reboot #{deploy_id}")

    exit info if rc == false

    OpenNebula.log_debug("Domain #{deploy_id} successfully rebooted.")
  end

  # ------------------------------------------------------------------------ #
  # Migrate                                                                  #
  # ------------------------------------------------------------------------ #
  def migrate(deploy_id, dst_host, src_host)
    src_url  = "vpx://#{@vcenter}/#{@datacenter}/#{src_host}/?no_verify=1"
    dst_url  = "vpx://#{@vcenter}/#{@datacenter}/#{dst_host}/?no_verify=1"

    mgr_cmd  = "-r virsh -c #{src_url} migrate #{deploy_id} #{dst_url}"

    rc, info = do_action(mgr_cmd)

    exit info if rc == false
  end

  # ------------------------------------------------------------------------ #
  # Monitor a VM                                                             #
  # ------------------------------------------------------------------------ #
  def poll(deploy_id)
    rc, info = do_action("virsh -c #{@uri} --readonly dominfo #{deploy_id}")

    return "STATE=d" if rc == false

    state = ""
    usedmemory = ""
    usedcpu = ""

    info.split('\n').each{ |line|
      mdata = line.match("^State: (.*)")

      if mdata
        state = mdata[1].strip
      end

    }

    case state
    when "running","blocked","shutdown","dying"
      state_short = 'a'
    when "paused"
      state_short = 'p'
    when "crashed"
      state_short = 'c'
    else
      state_short = 'd'
    end

    rc, info = do_action("/usr/lib/vmware-vcli/apps/vm/vminfo.pl --username #{@user} --password #{@pass} --server #{@host} --vmname #{deploy_id}")

    info.split("\n").each{ |line|
      mdata = line.match("^Host memory usage:\ *(.*) MB")

      if mdata
        usedmemory = mdata[1].strip.to_i * 1024
        next
      end

      mdata = line.match("^Cpu usage:\ *(.*) MHz")
      if mdata
        usedcpu = mdata[1].strip.to_f / 1000
        next
      end

    }

    return "STATE=#{state_short} USEDMEMORY=#{usedmemory} USEDCPU=#{usedcpu}"
  end

  # ------------------------------------------------------------------------ #
  # Restore a VM from a previously saved checkpoint                          #
  # ------------------------------------------------------------------------ #
  def restore(checkpoint)
    begin
      # Define the VM
      dfile = File.dirname(File.dirname(checkpoint)) + "/deployment.0"
    rescue => e
      OpenNebula.log_error("Can not open checkpoint #{e.message}")
      exit -1
    end

    deploy_id = define_domain(dfile)

    exit -1 if deploy_id.nil?

    # Revert snapshot VM
    # Note: This assumes the checkpoint name is "checkpoint", to change
    # this it is needed to change also [1]
    #
    # [1] $ONE_LOCATION/lib/remotes/vmm/vmware2/checkpoint

    rc, info = do_action(
    "virsh -c #{@uri} snapshot-revert #{deploy_id} checkpoint")

    if rc == true then

      # Delete checkpoint
      rc, info = do_action(
      "virsh -c #{@uri} snapshot-delete #{deploy_id} checkpoint")

      OpenNebula.log_error("Could not delete snapshot") if rc == false
    end
  end

  # ------------------------------------------------------------------------ #
  # Saves a VM taking a snapshot                                             #
  # ------------------------------------------------------------------------ #
  def save(deploy_id)

    # Here when the save is an actual save, we shutdown gracefully the machine
    state = get_state(deploy_id)
    if state[0] == "5" then
      # shutdown the VM
      shutdown(deploy_id)
    else
      # Take a snapshot for the VM
      rc, info = do_action("virsh -c #{@uri} snapshot-create #{deploy_id} #{CHECKPOINT}")
      exit info if rc == false
      # Suspend VM
      rc, info = do_action("virsh -c #{@uri} suspend #{deploy_id}")
      exit info if rc == false

      # Undefine VM
      undefine_domain(deploy_id)
    end

  end

  # ------------------------------------------------------------------------ #
  # Shutdown a VM                                                            #
  # ------------------------------------------------------------------------ #
  def shutdown(deploy_id)
    rc, info = do_action("virsh -c #{@uri} shutdown #{deploy_id}")

    if rc == false
      rc, info = do_action("/usr/lib/vmware-vcli/apps/vm/vmcontrol.pl --username #{@user} --password #{@pass} --server #{@host} --vmname #{deploy_id} --operation poweroff")
      exit info if rc == false
    end

    counter = 0

    begin
      rc, info = do_action("virsh -c #{@uri} list")
      info     = "" if rc == false

      sleep SHUTDOWN_INTERVAL

      counter = counter + SHUTDOWN_INTERVAL
    end while info.match(deploy_id) and counter < SHUTDOWN_TIMEOUT

    if counter >= SHUTDOWN_TIMEOUT
      OpenNebula.error_message(
      "Timeout reached, VM #{deploy_id} is still alive")
      exit - 1
    end

    undefine_domain(deploy_id)
  end

  # ######################################################################## #
  #                          DRIVER HELPER FUNCTIONS                         #
  # ######################################################################## #

  private

  #Generates an ESX command using ttyexpect
  def esx_cmd(command)
    cmd = "#{BIN_LOCATION}/tty_expect -u #{@user} -p #{@pass} #{command}"
  end

  #Performs a action usgin libvirt
  def do_action(cmd, log=true)
    rc = LocalCommand.run(esx_cmd(cmd))

    if rc.code == 0
      return [true, rc.stdout]
    else
      err = "Error executing: #{cmd} err: #{rc.stderr} out: #{rc.stdout}"
      OpenNebula.log_error(err) if log
      return [false, rc.code]
    end
  end

  # Undefines a domain in the ESX hypervisor
  def undefine_domain(id)
    rc, info = do_action("virsh -c #{@uri} undefine #{id}")

    if rc == false
      OpenNebula.log_error("Error undefining domain #{id}")
      OpenNebula.log_error("Domain #{id} has to be undefined manually")
      return info
    end

    return 0
  end

  #defines a domain in the ESX hypervisor
  def define_domain(dfile)
    deploy_id = nil
    rc, info  = do_action("virsh -c #{@uri} define #{dfile}")

    return nil if rc == false

    info.split('\n').each{ |line|
      mdata = line.match("Domain (.*) defined from (.*)")

      if mdata
        deploy_id = mdata[1]
        break
      end
    }

    deploy_id.strip!

    return deploy_id
  end

  def domain_defined?(one_id)
    rc, info  = do_action("virsh -c #{@uri} dominfo one-#{one_id}", false)

    return rc
  end

  def get_state(deploy_id)
    vmpool = VirtualMachinePool.new(@client)
    return -1 if OpenNebula.is_error?(vmpool)

    vmpool.info_all

    state = vmpool.retrieve_elements("/VM_POOL/VM[DEPLOY_ID='#{deploy_id}']/LCM_STATE")
    if state
      return state
    else
      OpenNebula.log_error("No LCM_STATE attribute found for vm deploy id #{deploy_id}")
      exit -1
    end
  end
end
