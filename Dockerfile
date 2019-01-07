FROM alpine:3.8

RUN apk update && \
    mkdir -p /code

ADD smanage.sh /code
ENTRYPOINT ["/bin/bash" , "/code/smanage.sh"]
