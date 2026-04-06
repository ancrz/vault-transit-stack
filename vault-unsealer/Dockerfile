FROM alpine:3.19

RUN apk add --no-cache curl jq

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as non-root
RUN adduser -D -u 1000 unsealer
USER unsealer

ENTRYPOINT ["entrypoint.sh"]
