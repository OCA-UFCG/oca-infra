# -*- mode: ruby -*-
# vi: set ft=ruby :

SSH_KEY_PATH = '~/.ssh/id_rsa'

Vagrant.configure("2") do |config|
  config.vm.define "vagrant-oca" do |oca|
    oca.vm.box = "ubuntu/jammy64"
    oca.vm.hostname = "vagrant-oca" 
    oca.vm.network "private_network", ip: "192.168.56.200"

    oca.ssh.insert_key = false
    oca.ssh.private_key_path = ['~/.vagrant.d/insecure_private_key', SSH_KEY_PATH]
    oca.vm.provision "file", source: "#{SSH_KEY_PATH}.pub", destination: "~/.ssh/authorized_keys"
  end
end
