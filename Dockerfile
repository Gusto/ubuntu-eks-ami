FROM hashicorp/packer

RUN apk add make
RUN mkdir /packer
WORKDIR packer
ENTRYPOINT []
