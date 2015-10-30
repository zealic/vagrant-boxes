###########################################################
# Definitions
###########################################################
CONFIG           = YAML.load(IO.read('config.yml'))
FORMATS          = ["ova", "vagrant"]
DEFAULT_MANIFEST = 'centos-7-devenv'
DEFAULT_PROVIDER = 'virtualbox'

class PackerTemplate
  attr_reader :build_format, :manifest, :provider
  attr_reader :file, :packer_template, :builder_template

  def initialize(build_format, manifest, provider, task_env = nil)
    defaults = CONFIG['defaults']
    @build_format = build_format || defaults['build_format']
    @manifest = normalize_manifest(manifest || defaults['manifest'])
    @provider = provider || defaults['provider']
    @file = File.join(get_basedir(), "packer-template.json")
    FileUtils.mkdir_p(get_basedir())

    # Load packer template
    File.open("boxes/#{@manifest}/template.json", "r" ) do |f|
      @packer_template = JSON.load(f)
    end
    if @packer_template["builders"].count != 1 then
      fail("Invalid template builders count, must be 1.") 
    end
    @builder_template = @packer_template['builders'][0].clone
    @packer_template['builders'] = []

    # Setup variables
    mf_vars = CONFIG["manifests"][@manifest]
    variables = mf_vars[task_env] || mf_vars['_'].each do |k,v|
      @packer_template['variables'][k] = v
    end
    @packer_template['variables']['atlas_user']     = CONFIG['atlas_user']
    @packer_template['variables']['version']        = CONFIG['version']
    @packer_template['variables']['template_name']  = @manifest
    @packer_template['variables']['build_format']   = @build_format
    @packer_template['variables']['provider']       = @provider
  end

  def build()
    generate()

    # Run packer build
    Dir.chdir(get_basedir()) do
      FileUtils.rm_rf(Dir.glob("output-#{@build_format}"))
      filename = File.basename(@file)
      exec "sh", "-c", "packer build -only=#{@build_format} #{filename}"
    end
  end

  def generate()
    # Generate packer template
    template = @packer_template.clone
    template['builders'].push(make_builder(@build_format))

    # For vagrant only instruction
    if @build_format != 'vagrant' then
      template['builders'].push(make_builder('vagrant'))
    end

    # Normalize provisioners
    (template['provisioners'] || []).each do |p|
      if p['type'] == 'shell' then
        {
          'BUILD_FORMAT': @build_format,
          'BUILD_MANIFEST': @manifest,
          'BUILD_PROVIDER': @provider
        }.each do |k, v|
          p['environment_vars'].push("#{k}=#{v}")
        end
      end
    end

    # Generate template
    IO.binwrite(@file, JSON.pretty_generate(template))

    # Generate ks template
    ks_template = IO.read("boxes/#{@manifest}/ks.cfg")
    Dir.chdir(get_basedir()) do
      ks_scope = @packer_template['variables'].each_with_object({}){|(k,v), h| h[k.to_sym] = v}
      # kickstart file not support CRLF newline
      IO.binwrite("ks.cfg", ks_template % ks_scope)
    end

    # Copy scripts
    target_dir = get_basedir()
    FileUtils.rm_rf(Dir.glob(target_dir + "/scripts"))
    FileUtils.cp_r("scripts", target_dir)
  end

  def push()
    generate()

    Dir.chdir(get_basedir()) do
      FileUtils.rm_rf(Dir.glob("output-#{@name}"))
      filename = File.basename(@file)
      atlas_name = "#{CONFIG["atlas_user"]}/#{@manifest}"
      exec 'packer', 'push', "-name=#{atlas_name}", filename
    end
  end

  private
  def is_debian()
    @manifest.start_with?("debian")
  end

  private
  def is_centos()
    @manifest.start_with?("centos")
  end

  private
  def make_builders(name)
    builder = @builder_template.clone
    builder['name'] = name
    template['builders'].push(builder)
    return builder
  end

  private
  def make_builder(format)
    builder = @builder_template.clone
    builder['name'] = format

    provider = @provider
    # Formats
    if format == "ova" then
      provider = "virtualbox"
      builder['hard_drive_interface'] = "scsi"
      builder['guest_additions_mode'] = "disable"
      builder['format'] = "ova"
      builder['export_opts'] = ["--options", "manifest,nomacs"]
    end

    if provider == "virtualbox" then
      builder['type'] = "virtualbox-iso"
      if is_debian then
        builder['guest_os_type'] = "Debian_64"
      elsif is_centos then
        builder['guest_os_type'] = "RedHat_64"
      else
        builder['guest_os_type'] = "Other"
      end
      builder['vboxmanage'] = [
        ["modifyvm", "{{.Name}}", "--memory", "{{user `memory_size`}}"],
        ["modifyvm", "{{.Name}}", "--cpus", "{{user `cpu_count`}}"]
      ]
    elsif provider == "vmware" then
      builder['type'] = "vmware-iso"
      if is_debian then
        builder['guest_os_type'] = "debian8-64"
      elsif is_centos then
        builder['guest_os_type'] = "centos-64"
      else
        builder['guest_os_type'] = "Other"
      end
      builder['version'] = '11'
      builder['vmx_data'] = {
        "memsize": "{{user `memory_size`}}",
        "numvcpus": "{{user `cpu_count`}}",
        "vhv.enable": "TRUE"
      }
    elsif provider == "qemu" then
      builder['type'] = "qemu"
      builder['qemuargs'] = [
        ["-nographic", ""]
      ]
      builder["headless"] = "true"
    else
      fail("Not supported provider '#{provider}'.")
    end

    return builder
  end

  def normalize_manifest(manifest)
    manifests = Dir['boxes/*/'].map { |a| File.basename(a) }
    unless manifests.include?(manifest) then
      #fail("Invalid manifest '#{manifest}', must be in #{manifests}.") 
    end
    return manifest
  end

  private
  def get_basedir()
    return ".target/#{@manifest}"
  end
end
