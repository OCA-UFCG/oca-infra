# oca-infra

## Installation

### Always required
- Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#pipx-install)
- Install [terraform](https://developer.hashicorp.com/terraform/install)

### Test required
- Install [vagrant](https://developer.hashicorp.com/vagrant/install)
- Install [virtualbox](https://www.virtualbox.org/wiki/Downloads)

## Configuration

## Certs configuration
1. Add your SSL certs as `./certs/lsd.*` into `./certs`
```
## Example:
certs/
├── lsd.crt
├── lsd.key
└── lsd.pem
```

### Ansible Configuration
1. Configure Ansible inventory in `ansible/hosts.ini`:
```ini
[server]
<ip_vm1> ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa # aws oca-runner

[monitor]
<ip_vm3> ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa # aws monitor

[all:vars]
ansible_python_interpreter=/usr/bin/python3
```

2. Configure Ansible vars in `ansible/deploy/vars.yml` and `ansible/monitor/vars.yml`:
```
---
# vars file for roles/deploy
container_port: 3000
container_name: oca-frontend-app
docker_image: ocaufcg/oca-frontend
dns_name: <your_dns>

---
# vars file for roles/monitor
dns_name: <your_dns> 
ips_to_monitor: [<ip_vm1>, <ip_vm2>]
mail_app_user: 'mail_user' # emails sender 
mail_app_pass: 'mail_app_password' # password
mail_app_to: 'mail_receiver' # emails receiver
```

## Usage
### Running Ansible Playbooks
1. Run a playbook on the inventory:
```bash
cd ansible
ansible-playbook playbook.yml
```

2. Also, you can run using the Makefile:
```bash
# For initial setup
make ansible-setup

# For deployment
make ansible-deploy

# For monitoring configuration
make ansible-monitor

# To start Docker Compose services for deployment
make compose-deploy

# To start Docker Compose services for monitoring
make compose-monitor
```

### Running Terraform Scripts
```hcl
terraform plan -out "tfplan"
terraform apply "tfplan"
```

## Testing with Vagrant

1. Start the Vagrant environment:
```bash
vagrant up
```

2. To connect to the machines:
```bash
vagrant ssh vagrant-oca
vagrant ssh vagrant-monitoring
```

3. To temporarily stop the machines:
```bash
vagrant halt
```

4. To destroy the environment when no longer needed:
```bash
vagrant destroy
```
