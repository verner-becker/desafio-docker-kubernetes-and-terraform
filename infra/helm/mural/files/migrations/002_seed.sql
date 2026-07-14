-- Seed opcional: só popula se a tabela estiver vazia.
-- Útil para ver a app "com vida" logo no primeiro acesso.

INSERT INTO messages (author, content)
SELECT 'Full Cycle', 'Bem-vindo ao desafio Docker + Kubernetes + Terraform!'
WHERE NOT EXISTS (SELECT 1 FROM messages);
