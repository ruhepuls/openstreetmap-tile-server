.PHONY: build push test

DOCKER_IMAGE=cybertec-postgresql/openstreetmap-tile-server

build:
	docker build -t ${DOCKER_IMAGE} .

push: build
	docker push ${DOCKER_IMAGE}:latest

test: build
	docker run --rm -v ${PWD}/openstreetmap-rendered-tiles:/var/lib/mod_tile --env-file=cybertec.env -e UPDATES=enabled ${DOCKER_IMAGE} import
	docker run --rm -v ${PWD}/openstreetmap-rendered-tiles:/var/lib/mod_tile --env-file=cybertec.env -e UPDATES=enabled -p 8080:80 ${DOCKER_IMAGE} run

stop:
	docker rm -f `docker ps | grep '${DOCKER_IMAGE}' | awk '{ print $$1 }'` || true

