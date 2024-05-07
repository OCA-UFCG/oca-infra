#script de deploy

git pull

#condição para ver se a branch ta atualizada. Se tiver, não faz nada. Se não tiver, executa os proximos comandos para realizar deploy.

if [ `git rev-parse HEAD` = `git rev-parse @{u}` ]; then
    echo "Branch is up to date"
else
    echo "Branch is not up to date"
    sudo make docker-stop

    sudo make docker-build-prod

    sudo make docker-run-prod
fi