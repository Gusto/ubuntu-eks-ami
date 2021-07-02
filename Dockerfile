FROM hashicorp/packer:1.7.2

RUN apk add make
RUN mkdir /packer
WORKDIR packer
ENTRYPOINT []
