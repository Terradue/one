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
  # Clone a virtual disk                                                     #
  # ------------------------------------------------------------------------ #
  def clone(src, dst)

    # map src to VMWARE HOST src
    img_src = src.gsub(VAR_LOCATION + "/","")

    imagestore = get_host_image_store_path(@host)
    datastore = get_host_data_store_path(@host)

    dst_path = dst.gsub(/\/disk\..*/,"")

    # create the directory
    rc, info = do_vifs("-f --mkdir '[#{datastore}] #{dst_path}'")

    # delete eventual previous disk
    rc, info = do_vmkfs("-U '[#{datastore}] #{dst}'")

    # Clone the disk
    rc, info = do_vmkfs("-i '[#{imagestore}] #{img_src}' -d thin '[#{datastore}] #{dst}'")

    if rc == false
      OpenNebula.log_error("Error during cloning the virtual disk on the host #{@host}")
      exit info
    end

    return 0
  end

  # ------------------------------------------------------------------------ #
  # delete                                                                   #
  # ------------------------------------------------------------------------ #
  def delete(dst)

    datastore = get_host_data_store_path(@host)

    # create the directory
    rc, info = do_vifs("-f --rmdir '[#{datastore}] #{dst}'")

    if rc == false
      OpenNebula.log_error("Error during delete the virtual disk(s) on the host #{@host}")
      exit info
    end

    return 0
  end

  #Performs a action usgin vifs
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

  #Performs a action usgin vmkfstools
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
