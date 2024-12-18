SHELL := /bin/bash

ansible-setup:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags setup

ansible-deploy:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags deploy

ansible-monitor:
	ansible-playbook -i ./ansible/hosts.ini ./ansible/playbook.yml --tags monitor

compose-deploy:
	docker compose -f ./ansible/roles/deploy/templates/docker-compose.yml up -d

compose-monitor:
	docker compose -f ./ansible/roles/monitor/templates/docker-compose.yml up -d