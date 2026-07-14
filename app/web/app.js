// Front em React SEM build step.
//
// Importamos React + htm direto da CDN (esm.sh) como ES modules. htm dá a
// ergonomia do JSX usando template strings, então não precisamos de Babel,
// Vite ou node_modules — o arquivo roda direto no browser. Do ponto de vista
// da infra, isto continua sendo UM arquivo estático servido pelo nginx: o
// Dockerfile, o docker-compose e o Helm não mudam em nada.
//
// A API continua sendo falada por caminho relativo (/api/...); quem roteia
// para o serviço da API é o nginx (proxy_pass ${API_UPSTREAM}).

import React, { useCallback, useEffect, useMemo, useState } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(React.createElement);
const API = "/api/messages";

// ---- helpers ---------------------------------------------------------------

function initials(name) {
  const parts = (name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

// Cor determinística a partir do nome — cada autor ganha um avatar com tom próprio.
function hueFor(name) {
  let h = 0;
  for (const ch of name || "") h = (h * 31 + ch.charCodeAt(0)) % 360;
  return h;
}

const rtf = new Intl.RelativeTimeFormat("pt-BR", { numeric: "auto" });
function relativeTime(iso) {
  if (!iso) return "";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const diffSec = Math.round((then - Date.now()) / 1000);
  const table = [
    ["year", 31536000],
    ["month", 2592000],
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  for (const [unit, secs] of table) {
    if (Math.abs(diffSec) >= secs) return rtf.format(Math.round(diffSec / secs), unit);
  }
  return "agora mesmo";
}

// ---- componentes -----------------------------------------------------------

function Avatar({ name }) {
  const style = {
    background: `linear-gradient(135deg, hsl(${hueFor(name)} 70% 55%), hsl(${(hueFor(name) + 40) % 360} 70% 45%))`,
  };
  return html`<div class="avatar" style=${style} aria-hidden="true">${initials(name)}</div>`;
}

function MessageCard({ msg }) {
  return html`
    <li class="message">
      <${Avatar} name=${msg.author} />
      <div class="message-body">
        <div class="message-head">
          <strong>${msg.author}</strong>
          <time title=${msg.created_at || ""}>${relativeTime(msg.created_at)}</time>
        </div>
        <p>${msg.content}</p>
      </div>
    </li>
  `;
}

function Composer({ onPublish, publishing }) {
  const [author, setAuthor] = useState("");
  const [content, setContent] = useState("");
  const remaining = 280 - content.length;

  const submit = async (e) => {
    e.preventDefault();
    const a = author.trim();
    const c = content.trim();
    if (!a || !c || publishing) return;
    const ok = await onPublish(a, c);
    if (ok) setContent("");
  };

  return html`
    <form class="card composer" onSubmit=${submit}>
      <input
        class="field"
        placeholder="Seu nome"
        maxLength=${60}
        value=${author}
        onInput=${(e) => setAuthor(e.target.value)}
        required
      />
      <textarea
        class="field"
        placeholder="Deixe um recado..."
        maxLength=${280}
        value=${content}
        onInput=${(e) => setContent(e.target.value)}
        required
      ></textarea>
      <div class="composer-foot">
        <span class=${"counter" + (remaining < 20 ? " counter-low" : "")}>${remaining}</span>
        <button type="submit" disabled=${publishing || !author.trim() || !content.trim()}>
          ${publishing ? "Publicando…" : "Publicar"}
        </button>
      </div>
    </form>
  `;
}

function App() {
  const [messages, setMessages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [publishing, setPublishing] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try {
      const res = await fetch(API);
      if (!res.ok) throw new Error("HTTP " + res.status);
      setMessages(await res.json());
      setError("");
    } catch (err) {
      setError("Não foi possível carregar os recados: " + err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const publish = useCallback(
    async (author, content) => {
      setPublishing(true);
      try {
        const res = await fetch(API, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ author, content }),
        });
        if (!res.ok) throw new Error("HTTP " + res.status);
        setError("");
        await load();
        return true;
      } catch (err) {
        setError("Falha ao publicar: " + err.message);
        return false;
      } finally {
        setPublishing(false);
      }
    },
    [load]
  );

  const count = useMemo(() => messages.length, [messages]);

  return html`
    <main class="container">
      <header class="hero">
        <h1>Mural de Recados</h1>
        <p class="subtitle">Desafio Docker · Kubernetes · Terraform — Full Cycle</p>
      </header>

      <${Composer} onPublish=${publish} publishing=${publishing} />

      ${error && html`<p class="status error" role="alert">${error}</p>`}

      <section class="feed">
        <div class="feed-head">
          <h2>Recados</h2>
          ${!loading && html`<span class="badge">${count}</span>`}
        </div>

        ${loading
          ? html`<p class="status">Carregando recados…</p>`
          : count === 0
          ? html`<div class="empty">Nenhum recado ainda. Seja o primeiro! ✍️</div>`
          : html`<ul class="messages">
              ${messages.map((m) => html`<${MessageCard} key=${m.id} msg=${m} />`)}
            </ul>`}
      </section>

      <footer class="foot">Servido por nginx · API em Go · Postgres</footer>
    </main>
  `;
}

createRoot(document.getElementById("root")).render(html`<${App} />`);
