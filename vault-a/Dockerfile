ARG VAULT_TAG=1.15.4

FROM hashicorp/vault:${VAULT_TAG}

# Re-declare ARGs after FROM so they are in scope for subsequent instructions
ARG UID_ARG=1000
ARG GID_ARG=1000

# Install shadow for full adduser/addgroup functionality and gettext for envsubst
RUN apk add --no-cache shadow gettext

# Create a non-root user and group with specified UID/GID
RUN if ! getent group vault > /dev/null; then \
        addgroup -g ${GID_ARG} vault; \
    fi && \
    if ! id -u vault > /dev/null 2>&1; then \
        adduser -u ${UID_ARG} -D -G vault vault; \
    fi

# Set ownership of Vault's data directory
RUN chown -R ${UID_ARG}:vault /vault/file

# Copy active config template (envsubst resolves at runtime)
COPY ./config/vault.hcl.template /vault/config/vault.hcl.template

# Copy reference templates (not used at runtime)
COPY ./config/vault.hcl.template.init /usr/local/bin/config_templates/vault.hcl.template.init
COPY ./config/vault.hcl.template.final /usr/local/bin/config_templates/vault.hcl.template.final

# Set the user for the Vault process
USER ${UID_ARG}:${GID_ARG}

# Expose the Vault port
EXPOSE 8200

# Set the entrypoint
COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
