-- Criacao dos databases para desenvolvimento local
-- Este arquivo e executado automaticamente pelo postgres:alpine na inicializacao
-- No K8s, o mesmo script e executado via initdb do Helm chart do PostgreSQL

CREATE DATABASE fiapx_auth;
CREATE DATABASE fiapx_upload;
CREATE DATABASE fiapx_processor;

GRANT ALL PRIVILEGES ON DATABASE fiapx_auth TO fiapx;
GRANT ALL PRIVILEGES ON DATABASE fiapx_upload TO fiapx;
GRANT ALL PRIVILEGES ON DATABASE fiapx_processor TO fiapx;
