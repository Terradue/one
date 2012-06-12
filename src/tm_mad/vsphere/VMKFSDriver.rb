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

ONE_LOCATION=ENV["ONE_LOCATION"] if !ONE_LOCATION

if !ONE_LOCATION
  RUBY_LIB_LOCATION="/usr/lib/one/ruby"
else
  RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
end

$: << RUBY_LIB_LOCATION

require "scripts_common"
require 'yaml'
require "CommandManager"
require 'OpenNebula'

include OpenNebula

class VMKSFSDriver

  # -------------------------------------------------------------------------#
  # Set up the environment for the driver                                    #
  # -------------------------------------------------------------------------#

  if !ONE_LOCATION
    BIN_LOCATION = "/usr/bin"
    LIB_LOCATION = "/usr/lib/one"
    ETC_LOCATION = "/etc/one/"
    VAR_LOCATION = "/var/lib/one"
  else
    LIB_LOCATION = ONE_LOCATION + "/lib"
    BIN_LOCATION = ONE_LOCATION + "/bin"
    ETC_LOCATION = ONE_LOCATION  + "/etc"
    VAR_LOCATION = ONE_LOCATION + "/var"
  end

  CONF_FILE   = ETC_LOCATION + "/vmwarerc"

  ENV['LANG'] = 'C'

  VMKFSTOOLS_PREFIX  = "/usr/bin/vmkfstools"
  VIFS_PREFIX  = "/usr/bin/vifs"

  def initialize(host)
    conf  = YAML::load(File.read(CONF_FILE))

    @host  = host

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

    # retrieve the remote datastores
    # network file system to ONE
    @imagestore = get_host_image_store_path(@host)
    # local datastore for runtime
    @datastore = get_host_data_store_path(@host)

  end

  # ######################################################################## #
  #                       VMWARE DRIVER ACTIONS                              #
  # ######################################################################## #

  # ------------------------------------------------------------------------ #
  # Create a virtual disk                                                    #
  # ------------------------------------------------------------------------ #
  def mkimage(size, format, dst)

    # retrieve the vm deploy id and the disk id
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    # build the ESXi disk remote path
    remote_dst = "one-"+vm_id+"/"+disk_id+".vmdk"
    # directory path
    dst_path = remote_dst.gsub(/\/disk\..*/,"")
    # create the directory if not existing
    rc, info = do_vifs("-f --mkdir '[#{@datastore}] #{dst_path}'", false)

    # delete eventual previous disk
    rc, info = do_vmkfs("-U '[#{@datastore}] #{remote_dst}'", false)

    # Clone the disk
    rc, info = do_vmkfs("-c #{size}M -d thin '[#{@datastore}] #{remote_dst}'")

    # if cloning failed
    if rc == false
      OpenNebula.log_error("Error during creating the virtual disk '[#{@datastore}] #{remote_dst}' on the host #{@host}")
      exit info
    end

    OpenNebula.log_info("Successfully created virtual disk '[#{@datastore}] #{remote_dst}' on the host #{@host}")
    return 0
  end

  # ------------------------------------------------------------------------ #
  # Clone a virtual disk                                                     #
  # ------------------------------------------------------------------------ #
  def clonevmdk(src, dst)

    # retrieve the vm deploy id and the disk id
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    # build remote ESXi path to one mapping
    img_src = src.gsub(VAR_LOCATION + "/","")
    # build the ESXi disk remote path
    remote_dst = "one-"+vm_id+"/"+disk_id+".vmdk"
    # directory path
    dst_path = remote_dst.gsub(/\/disk\..*/,"")

    # create the directory if not existing
    rc, info = do_vifs("-f --mkdir '[#{@datastore}] #{dst_path}'", false)

    # delete eventual previous disk
    rc, info = do_vmkfs("-U '[#{@datastore}] #{remote_dst}'", false)

    # Clone the disk
    rc, info = do_vmkfs("-i '[#{@imagestore}] #{img_src}/disk.vmdk' -d thin '[#{@datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during cloning the virtual disk '[#{@imagestore}] #{img_src}/disk.vmdk' to '[#{@datastore}] #{remote_dst}' on the host #{@host}")
      exit info
    end

    OpenNebula.log_info("Successfully cloned virtual disk '[#{@imagestore}] #{img_src}' to '[#{@datastore}] #{remote_dst}' on the host #{@host}")
    return 0
  end

  # ------------------------------------------------------------------------ #
  # Clone a virtual disk                                                     #
  # ------------------------------------------------------------------------ #
  def copyiso(src, dst)

    # retrieve the vm deploy id and the disk id
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    # build remote ESXi path to one mapping
    img_src = src.gsub(VAR_LOCATION + "/","")
    # build the ESXi disk remote path
    remote_dst = "one-"+vm_id+"/"+disk_id+".iso"
    # directory path
    dst_path = remote_dst.gsub(/\/disk\..*/,"")

    # create the directory if not existing
    rc, info = do_vifs("-f --mkdir '[#{@datastore}] #{dst_path}'", false)

    # delete eventual previous disk
    rc, info = do_vifs("--rm '[#{@datastore}] #{remote_dst}'", false)

    # Clone the disk
    rc, info = do_vifs("-c '[#{@imagestore}] #{img_src}' '[#{@datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during cloning the ISO virtual disk '[#{@imagestore}] #{img_src}' '[#{@datastore}] #{remote_dst}' on the host #{@host}")
      exit info
    end

    OpenNebula.log_info("Sucessfully cloned ISO virtual disk '[#{@imagestore}] #{img_src}' '[#{@datastore}] #{remote_dst}' on the host #{@host}")
    return 0
  end

  # ------------------------------------------------------------------------ #
  # delete file                                                              #
  # ------------------------------------------------------------------------ #
  def delete(dst)

    # retrieve the vm deploy id and the path
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    path = dst.gsub(VMDIR.squeeze("/"),"").split("/",3)[2]

    # build the ESXi disk remote path
    remote_dst = "one-"+vm_id+"/"+path

    # remove the file
    rc, info = do_vifs("-f --rm '[#{@datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during delete the file '[#{@datastore}] #{remote_dst}' on the host #{@host}")
      exit info
    end

    OpenNebula.log_info("Sucessfully deletes file '[#{@datastore}] #{remote_dst}' on the host #{@host}")
    return 0
  end

  # ------------------------------------------------------------------------ #
  # delete dir                                                               #
  # ------------------------------------------------------------------------ #
  def deletedisks(dst)

    # retrieve the vm deploy id and the path
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    path = dst.gsub(VMDIR.squeeze("/"),"").gsub("/images","").split("/",3)[2]

    # the remote VM dir
    remote_dst = "one-"+vm_id

    # list the directory
    rc, info = do_vifs("--dir '[#{@datastore}] #{remote_dst}'",false)
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        # skip headers
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        entrylist = line.match("disk\.[0-9]*.*")
        # if this is a disk
        if entrylist
          rc, info = do_vifs("-f --rm '[#{@datastore}] #{remote_dst}/#{line}'")
          if rc == false
            OpenNebula.log_error("Error during deleting the virtual disk '[#{@datastore}] #{remote_dst}/#{line}' on the host #{@host}")
            exit info
          end
        else
          next
        end
      }
    else
      exit 0
    end

    OpenNebula.log_info("Sucessfully deleted virtual disks in '[#{@datastore}] #{remote_dst}' on the host #{@host}")

    return 0
  end

  # ------------------------------------------------------------------------ #
  # move file to host                                                        #
  # ------------------------------------------------------------------------ #
  def mvto(src, dst)

    # clone
    clone(src,dst)

    # then delete
    delete(src)

    OpenNebula.log_info("Sucessfully moved virtual disk #{src} to #{dst} on the host #{@host}")

    return 0

  end

  # ------------------------------------------------------------------------ #
  # restore disks of a VM                                                    #
  # ------------------------------------------------------------------------ #
  def restoredisks(src, dst)

    # retrieve the vm deploy id
    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]

    # source is the save directory on one
    img_src = src.gsub(VAR_LOCATION + "/","")
    # remote VM directory on ESX(i) host
    remote_dst = "one-"+vm_id

    # create the directory
    rc, info = do_vifs("-f --mkdir '[#{@datastore}] #{remote_dst}'", false)

    # list the directory
    rc, info = do_vifs("--dir '[#{@imagestore}] #{img_src}'", false)
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        # if disk
        entrylist = line.match("disk\.[0-9]")
        if entrylist
          # test if directory
          rc, info = do_vifs("--dir '[#{@imagestore}] #{img_src}/line'", false)
          # VMWare disk
          if rc == true
            # delete eventual previous disk
            rc, info = do_vmkfs("-U '[#{@datastore}] #{remote_dst}/#{line}.vmdk'", false)
            # clone file
            rc, info = do_vmkfs("-i '[#{@imagestore}] #{img_src}/#{line}/disk.vmdk' -d thin '[#{@datastore}] #{remote_dst}/#{line}.vmdk'")
            # if cloning successful
            if rc == true
              # delete the original
              rc, info = do_vmkfs("-U '[#{@imagestore}] #{img_src}/#{line}/disk.vmdk'")
              # delete the original
              rc, info = do_vifs("-f --rmdir '[#{@imagestore}] #{img_src}/#{line}'")
            else
              OpenNebula.log_error("Error during move of the virtual disk '[#{@imagestore}] #{img_src}/#{line}' to '[#{@datastore}] #{remote_dst}/#{line}.vmdk' on the host #{@host}")
              exit info
            end
            # ISO disks
          else
            # delete eventual previous disk
            rc, info = do_vifs("-f --rm '[#{@datastore}] #{remote_dst}/#{line}.iso'", false)
            # clone file
            rc, info = do_vifs("-f -m '[#{@imagestore}] #{img_src}/#{line}' '[#{@datastore}] #{remote_dst}/#{line}.iso'")
            if rc == false
              OpenNebula.log_error("Error during move of the virtual disk '[#{@imagestore}] #{img_src}/#{line}' to '[#{@datastore}] #{remote_dst}/#{line}.iso' on the host #{@host}")
              exit info
            end
          end
        end
      }
    end

    OpenNebula.log_info("Successfully restored virtual disks from '[#{@imagestore}] #{img_src}' to '[#{@datastore}] #{remote_dst}' on the host #{@host}")

    return 0

  end

  # ------------------------------------------------------------------------ #
  # move directory from host                                                 #
  # ------------------------------------------------------------------------ #
  def savedisks(src, dst)

    # retrieve the vm deploy id
    vm_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[1]

    # destination will contain all VMWare files in save dir on one server
    vm_dst_path = dst.gsub(VAR_LOCATION + "/","")

    # create destination dir
    rc, info = do_vifs("-f --mkdir '[#{@imagestore}] #{vm_dst_path}'", false)

    # remote deploy id
    remote_src = "one-"+vm_id

    # list the directory
    rc, info = do_vifs("--dir '[#{@datastore}] #{remote_src}'", false)
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        # VMWare disks
        entrylist = line.match("disk\.[0-9]*\.vmdk")
        if entrylist
          dst_disk = line.gsub(".vmdk","")
          # create directory
          rc, info = do_vifs("--mkdir '[#{@imagestore}] #{vm_dst_path}/#{dst_disk}'", false)
          # clone file
          rc, info = do_vmkfs("-i '[#{@datastore}] #{remote_src}/#{line}' -d thin '[#{@imagestore}] #{vm_dst_path}/#{dst_disk}/disk.vmdk'")
          if rc == false
            OpenNebula.log_error("Error during saving virtual disk from '[#{@datastore}] #{remote_src}/#{line}' to '[#{@imagestore}] #{vm_dst_path}/#{dst_disk}/disk.vmdk' on the host #{@host}")
            exit info
          end
          # delete
          rc, info = do_vmkfs("-U '[#{@datastore}] #{remote_src}/#{line}'", false)
          next
        end
        entrylist = line.match("disk\.[0-9]*\.iso")
        if entrylist
          dst_disk = line.gsub(".iso","")
          # move file
          rc, info = do_vifs("-f -m '[#{@datastore}] #{remote_src}/#{line}' '[#{@imagestore}] #{vm_dst_path}/#{dst_disk}'")
          if rc == false
            OpenNebula.log_error("Error during saving virtual disk from '[#{@datastore}] #{remote_src}/#{line}' to '[#{@imagestore}] #{vm_dst_path}/#{dst_disk}' on the host #{@host}")
            exit info
          end
          next
        end
        entrylist = line.match("disk\.*\.vmdk")
        next if entrylist
        rc, info = do_vifs("-f --rm '[#{@datastore}] #{remote_src}/#{line}'")
      }
    end

    # delete the directory
    rc, info = do_vifs("-f --rmdir '[#{@datastore}] #{remote_src}'", false)

    OpenNebula.log_info("Sucessfully saved the virtual disks from '[#{@datastore}] #{remote_src}' to '[#{@imagestore}] #{vm_dst_path}' on the host #{@host}")

    `sudo /bin/chown oneadmin -R #{dst}`

    if $? == false
      OpenNebula.log_error("Error during fixing perm for #{dst}: sudo /bin/chown oneadmin -R #{dst}")
      exit info
    end

    return 0

  end

  # ------------------------------------------------------------------------ #
  # move disk from host                                                      #
  # ------------------------------------------------------------------------ #
  def savedisk(src, dst)

    # retrieve the vm deploy id and the path
    vm_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    # destination will contain all VMWare files in save dir on one server
    vm_dst_path = dst.gsub(VAR_LOCATION + "/","")

    # remote path on ESX(i) host
    remote_src = "one-"+vm_id+"/"+disk_id+".vmdk"

    # create destination dir
    rc, info = do_vifs("-f --mkdir '[#{@imagestore}] #{vm_dst_path}'", false)

    # clone the disk
    rc, info = do_vmkfs("-i '[#{@datastore}] #{remote_src}' -d thin '[#{@imagestore}] #{vm_dst_path}/disk.vmdk' ")

    if rc == false
      OpenNebula.log_error("Error during saving the virtual virtual disk '[#{@datastore}] #{remote_src}' '[#{@imagestore}] #{vm_dst_path}/disk.vmdk' on the host #{@host}")
      exit info
    end

    # delete the disk
    rc, info = do_vmkfs("-U '[#{@datastore}] #{remote_src}'")

    `sudo /bin/chown oneadmin -R #{dst}`

    if $? == false
      OpenNebula.log_error("Error during fixing perm for #{dst}: sudo /bin/chown oneadmin -R #{dst}")
      exit info
    end

    return 0

  end

  # ------------------------------------------------------------------------ #
  # private functions                                                        #
  # ------------------------------------------------------------------------ #
  private

  # Performs an action usgin vifs
  def do_vifs(cmd, log=true)
    rc = LocalCommand.run(VIFS_PREFIX + " --server #{@host} --username #{@user} --password #{@pass} "+cmd)

    if rc.code == 0
      return [true, rc.stdout]
    else
      err = "Error executing: " + VIFS_PREFIX + " --server #{@host} --username #{@user} --password **** "+cmd
      OpenNebula.log_error(err) if log
      return [false, rc.code]
    end
  end

  # Performs an action usgin vmkfstools
  def do_vmkfs(cmd, log=true)
    rc = LocalCommand.run(VMKFSTOOLS_PREFIX + " --server #{@host} --username #{@user} --password #{@pass} "+cmd)

    if rc.code == 0
      return [true, rc.stdout]
    else
      err = "Error executing: " + VMKFSTOOLS_PREFIX + " --server #{@host} --username #{@user} --password **** "+cmd
      OpenNebula.log_error(err) if log
      return [false, rc.code]
    end
  end

  # Get Host Image mapping
  def get_host_image_store_path(hostname)
    hpool = HostPool.new(@client)
    return -1 if OpenNebula.is_error?(hpool)

    hpool.info

    imagestore = hpool.retrieve_elements("/HOST_POOL/HOST[NAME='#{hostname}']/TEMPLATE/IMAGESTORE")
    if imagestore
      return imagestore
    else
      OpenNebula.log_error("No IMAGESTORE attribute found for host #{hostname}")
      exit -1
    end
  end

  # Get Host datastore
  def get_host_data_store_path(hostname)
    hpool = HostPool.new(@client)
    return -1 if OpenNebula.is_error?(hpool)

    hpool.info

    datastore = hpool.retrieve_elements("/HOST_POOL/HOST[NAME='#{hostname}']/TEMPLATE/DATASTORE")
    if datastore
      return datastore
    else
      OpenNebula.log_error("No DATASTORE attribute found for host #{hostname}")
      exit -1
    end
  end

end
