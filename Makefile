SHELL := /bin/bash

setup:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags setup

deploy:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags deploy

destroy:
	vagrant destroy -f vagrant-oca
