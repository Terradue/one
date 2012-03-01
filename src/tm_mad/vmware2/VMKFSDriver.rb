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

ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
  RUBY_LIB_LOCATION="/usr/lib/one/ruby"
  VMDIR="/var/lib/one"
else
  RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
  VMDIR=ONE_LOCATION+"/var"
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

  end

  # ######################################################################## #
  #                       VMWKFS DRIVER ACTIONS                              #
  # ######################################################################## #

  # ------------------------------------------------------------------------ #
  # Create a virtual disk                                                     #
  # ------------------------------------------------------------------------ #
  def mkimage(size, format, dst)

    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    remote_dst = "one-"+vm_id+"/"+disk_id+".vmdk"

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)

    dst_path = remote_dst.gsub(/\/disk\..*/,"")

    # create the directory
    rc, info = do_vifs("-f --mkdir '[#{datastore}] #{dst_path}'")

    # delete eventual previous disk
    rc, info = do_vmkfs("-U '[#{datastore}] #{remote_dst}'")

    # Clone the disk
    rc, info = do_vmkfs("-c #{size}M -d thin '[#{datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during creating the virtual disk on the host #{@host}")
      exit info
    end

    return 0
  end

  # ------------------------------------------------------------------------ #
  # Clone a virtual disk                                                     #
  # ------------------------------------------------------------------------ #
  def clone(src, dst)

    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    # map src to VMWARE HOST src
    img_src = src.gsub(VAR_LOCATION + "/","")

    remote_dst = "one-"+vm_id+"/"+disk_id+".vmdk"

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)

    dst_path = remote_dst.gsub(/\/disk\..*/,"")

    # create the directory
    rc, info = do_vifs("-f --mkdir '[#{datastore}] #{dst_path}'")

    # delete eventual previous disk
    rc, info = do_vmkfs("-U '[#{datastore}] #{remote_dst}'")

    # Clone the disk
    rc, info = do_vmkfs("-i '[#{imagestore}] #{img_src}' -d thin '[#{datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during cloning the virtual disk on the host #{@host}")
      exit info
    end

    return 0
  end

  # ------------------------------------------------------------------------ #
  # delete file                                                              #
  # ------------------------------------------------------------------------ #
  def delete(dst)

    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    path = dst.gsub(VMDIR.squeeze("/"),"").split("/",3)[2]

    remote_dst = "one-"+vm_id+"/"+path

    rc, info = do_vifs("-f --rm '[#{datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during delete the virtual disk(s) on the host #{@host}")
      exit info
    end

    return 0
  end

  # ------------------------------------------------------------------------ #
  # delete dir                                                               #
  # ------------------------------------------------------------------------ #
  def deletedir(dst)

    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    path = dst.gsub(VMDIR.squeeze("/"),"").gsub("/images","").split("/",3)[2]

    remote_dst = "one-"+vm_id

    datastore = get_host_data_store_path(@host)

    # list the directory
    rc, info = do_vifs("--dir '[#{datastore}] #{remote_dst}'")
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        # delete directory file
        rc, info = do_vifs("-f --rm '[#{datastore}] #{remote_dst}/#{line}'")
      }
    end

    # delete the directory
    rc, info = do_vifs("-f --rmdir '[#{datastore}] #{remote_dst}'")

    if rc == false
      OpenNebula.log_error("Error during delete the virtual disk(s) on the host #{@host}")
      exit info
    end

    return 0
  end

  # ------------------------------------------------------------------------ #
  # move file to host                                                        #
  # ------------------------------------------------------------------------ #
  def mvto(src, dst)

    clone(src,dst)

    delete(src)

    return 0

  end

  # ------------------------------------------------------------------------ #
  # move directory to host                                                   #
  # ------------------------------------------------------------------------ #
  def mvdirto(src, dst)

    vm_id = dst.gsub(VMDIR.squeeze("/"),"").split("/")[1]

    # source is the save directory on one server
    img_src = dst.gsub(VAR_LOCATION + "/","")

    remote_dst = "one-"+vm_id

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)
    
    # create the directory
    rc, info = do_vifs("-f --mkdir '[#{datastore}] #{remote_dst}'")

    # list the directory
    rc, info = do_vifs("--dir '[#{imagestore}] #{img_src}'")
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        entrylist = line.match("disk\.[0-9]*\.vmdk")
        if entrylist
          # delete eventual previous disk
          rc, info = do_vmkfs("-U '[#{datastore}] #{remote_dst}/#{line}'")
          # clone file
          rc, info = do_vmkfs("-i '[#{imagestore}] #{img_src}/#{line}' -d thin '[#{datastore}] #{remote_dst}/#{line}'")

          if rc == true
            # delete
            rc, info = do_vmkfs("-U '[#{imagestore}] #{img_src}/#{line}'")
          end
        end
      }
    end

    if rc == false
      OpenNebula.log_error("Error during cloning the virtual disk on the host #{@host}")
      exit info
    end

    return 0

  end

  # ------------------------------------------------------------------------ #
  # move directory from host                                                 #
  # ------------------------------------------------------------------------ #
  def mvdirfrom(src, dst)

    vm_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[1]

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)

    # destination will contain all VMWare files in save dir on one server
    vm_dst_path = dst.gsub(VAR_LOCATION + "/","")+"/images/"

    remote_src = "one-"+vm_id

    # list the directory
    rc, info = do_vifs("--dir '[#{datastore}] #{remote_src}'")
    entrylist = ""
    if rc == true
      info.split("\n").each{ |line|
        next if line.empty?
        entrylist = line.match(".*(Content Listing).*")
        next if entrylist
        entrylist = line.match(".*(\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-).*")
        next if entrylist
        entrylist = line.match("disk\.[0-9]*\.vmdk")
        if entrylist
          # clone file
          rc, info = do_vmkfs("-i '[#{datastore}] #{remote_src}/#{line}' -d thin '[#{imagestore}] #{vm_dst_path}/#{line}'")
          # delete
          rc, info = do_vmkfs("-U '[#{datastore}] #{remote_src}/#{line}'")
        end
        entrylist = line.match("disk\.*\.vmdk")
        next if entrylist
        rc, info = do_vifs("-f --rm '[#{datastore}] #{remote_src}/#{line}'")

      }
    end

    # delete the directory
    rc, info = do_vifs("-f --rmdir '[#{datastore}] #{remote_src}'")

    if rc == false
      OpenNebula.log_error("Error during saving the virtual machine on the host #{@host}")
      exit info
    end

    return 0

  end

  # ------------------------------------------------------------------------ #
  # move disk from host                                                      #
  # ------------------------------------------------------------------------ #
  def mvfrom(src, dst)

    vm_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[1]
    disk_id = src.gsub(VMDIR.squeeze("/"),"").split("/")[3]

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)

    # destination will contain all VMWare files in save dir on one server
    vm_dst_path = dst.gsub(VAR_LOCATION + "/","")

    remote_src = "one-"+vm_id+"/"+disk_id+".vmdk"

    # Clone the dir
    rc, info = do_vifs("-f --move '[#{datastore}] #{remote_src}' '[#{imagestore}] #{vm_dst_path}.vmdk' ")

    if rc == false
      OpenNebula.log_error("Error during saving the virtual machine on the host #{@host}")
      exit info
    end

    return 0

  end

  #Performs an action usgin vifs
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

  #Performs an action usgin vmkfstools
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

  # get Host Image mapping
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
