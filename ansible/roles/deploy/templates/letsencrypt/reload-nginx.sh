#!/bin/sh
# Recarrega o nginx depois que o certbot renova um certificado.
#
# GERADO PELO ANSIBLE (role deploy) -- nao editar no host.
#
# Por que isto existe: o nginx roda em container e le os certificados de
# /etc/letsencrypt. Quando o certbot renova, o arquivo em disco fica novo, mas o
# processo do nginx continua servindo o certificado que carregou quando subiu --
# ele nao rele sozinho. Sem este hook o site passa a servir certificado VENCIDO
# mesmo com o renovado em disco, e o sintoma so aparece meses depois.
#
# O certbot executa tudo que estiver em renewal-hooks/deploy/ uma vez por
# lineage, e somente quando a renovacao de fato aconteceu.
set -eu

CONTAINER='{{ nginx_container_name }}'

# Container parado nao e erro de renovacao: avisa e sai limpo, para nao marcar a
# renovacao como falha quando o certificado foi obtido com sucesso.
if [ "$(docker inspect -f '{% raw %}{{.State.Running}}{% endraw %}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "deploy-hook: container '$CONTAINER' nao esta rodando; reload ignorado" >&2
    exit 0
fi

docker exec "$CONTAINER" nginx -t
docker exec "$CONTAINER" nginx -s reload
