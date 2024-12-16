SHELL := /bin/bash

setup:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags setup

deploy:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags deploy

monitoring:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags monitor