-- Migration inicial do desafio.
-- IMPORTANTE: a API NÃO cria esta tabela sozinha (fricção intencional).
-- Esta migration precisa rodar ANTES de a API ficar pronta (/readyz depende dela).
-- No Kubernetes, o caminho natural é um Job que roda antes/junto do deploy da API.

CREATE TABLE IF NOT EXISTS messages (
    id         BIGSERIAL PRIMARY KEY,
    author     TEXT        NOT NULL,
    content    TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
