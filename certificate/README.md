## Run certobot
```
docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot/ --dry-run -d [domain-name]
# e.g:
#     docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot/ --dry-run -d oca.lsd.ufcg.edu.br
```

https://phoenixnap.com/kb/letsencrypt-docker