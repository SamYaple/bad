```console
# You may need to update the "resolver" line in the nginx.conf
# The github.com mirror volume is optional and can be dropped
docker run -d --name cacher \
           -v ./nginx.conf:/etc/nginx/nginx.conf:ro \
           -v deb_cache:/var/cache/nginx/deb \
           -v pip_cache:/var/cache/nginx/pip \
           -v /mnt/mirror/git/github.com:/srv/git:ro \
           -p 8081:80 \
           nginx
```
