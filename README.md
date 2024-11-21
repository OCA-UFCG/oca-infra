# oca-infra

## Installation
Install [vagrant](https://developer.hashicorp.com/vagrant/install)
Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#pipx-install)

## Execution
### ANSIBLE
How to run playbook Ansible:
```PowerShell
ansible-playbook playbook.yml 
```

### TERRAFORM
How to run main file Terraform:
```hcl
terraform plan -out "tfplan"
terraform apply "tfplan"
```

