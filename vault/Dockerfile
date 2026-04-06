ARG VAULT_TAG=1.15.4

FROM hashicorp/vault:${VAULT_TAG}

ARG UID_ARG=1000
ARG GID_ARG=1000

RUN apk add --no-cache shadow gettext

RUN if ! getent group vault > /dev/null; then \
        addgroup -g ${GID_ARG} vault; \
    fi && \
    if ! id -u vault > /dev/null 2>&1; then \
        adduser -u ${UID_ARG} -D -G vault vault; \
    fi

RUN chown -R ${UID_ARG}:vault /vault/file

COPY ./config/vault.hcl.template /vault/config/vault.hcl.template
COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${UID_ARG}:${GID_ARG}

EXPOSE 8200

ENTRYPOINT ["entrypoint.sh"]
