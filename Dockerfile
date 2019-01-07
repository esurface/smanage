FROM alpine:3.8

# docker build -t srcc/smanage .

RUN apk add --no-cache bash && \
    mkdir -p /code

ADD smanage.sh /code
RUN chmod u+x /code/smanage.sh
ENTRYPOINT ["/bin/bash" , "/code/smanage.sh"]
