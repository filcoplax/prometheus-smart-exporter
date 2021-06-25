FROM golang:1.16-alpine AS stage

LABEL maintianer="Peng Wenming <ffxgamer@163.com>"

COPY . /go/src 

WORKDIR /go/src

ENV GOPROXY=https://goproxy.io,direct

RUN go get github.com/markbates/pkger/cmd/pkger && \
    pkger -include /scripts && \
    CGO_ENABLED=0 go build \
        -ldflags="-X main.version=0.0.2 -X 'main.buildTime=`date`' -extldflags -static" \
        -o /go/bin/smart-exporter \
        ./cmd/smart-exporter

FROM alpine

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
     apk update && \
     apk add --no-cache bash smartmontools

EXPOSE 9111

COPY --from=stage /go/bin/smart-exporter /usr/bin/

ENTRYPOINT ["smart-exporter"]
