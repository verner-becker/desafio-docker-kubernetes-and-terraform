// API do desafio: um mural de recados simples que persiste no Postgres.
//
// Pontos de atenção (fricções INTENCIONAIS do desafio — veja o README):
//   - A API NÃO cria a tabela sozinha. O schema vem das migrations em ./migrations.
//     Se a migration não rodar antes, /readyz falha (a tabela não existe).
//   - /healthz  -> liveness: só diz que o processo está de pé (não toca no banco).
//   - /readyz   -> readiness: só fica pronto quando o banco responde E o schema existe.
//     Ligar a livenessProbe no /readyz derruba o pod antes do banco/migration
//     ficarem prontos (CrashLoop). Escolha a probe certa para cada endpoint.
//   - DATABASE_URL carrega a senha do banco. Nunca deve ir hardcoded num manifest;
//     no Kubernetes isso é um Secret.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Message struct {
	ID        int64     `json:"id"`
	Author    string    `json:"author"`
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
}

type server struct {
	pool *pgxpool.Pool
}

func main() {
	port := getenv("PORT", "8080")

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		// Falha rápida e clara: sem banco não há o que servir.
		log.Fatal("DATABASE_URL não definida — a app precisa da string de conexão do Postgres (no K8s, via Secret)")
	}

	// O pool conecta preguiçosamente; não derrubamos a app se o banco ainda
	// não subiu. Quem reflete a prontidão é a readiness (/readyz).
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		log.Fatalf("falha ao configurar pool do Postgres: %v", err)
	}
	defer pool.Close()

	s := &server{pool: pool}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/readyz", s.readyz)
	mux.HandleFunc("/api/messages", s.messages)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           logging(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("API ouvindo em :%s", port)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// healthz = liveness. Processo vivo => 200. Nunca toca no banco.
func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// readyz = readiness. Só fica pronto quando o banco responde E a tabela existe
// (ou seja, a migration já rodou). É isto que segura o tráfego até o app poder servir.
func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	var one int
	if err := s.pool.QueryRow(ctx, "SELECT 1 FROM messages LIMIT 1").Scan(&one); err != nil {
		// pgx devolve ErrNoRows quando a tabela existe mas está vazia — isso é OK.
		if !strings.Contains(err.Error(), "no rows") {
			http.Error(w, "not ready: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func (s *server) messages(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.listMessages(w, r)
	case http.MethodPost:
		s.createMessage(w, r)
	default:
		http.Error(w, "método não suportado", http.StatusMethodNotAllowed)
	}
}

func (s *server) listMessages(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, "SELECT id, author, content, created_at FROM messages ORDER BY created_at DESC LIMIT 100")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	out := []Message{}
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Author, &m.Content, &m.CreatedAt); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		out = append(out, m)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) createMessage(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Author  string `json:"author"`
		Content string `json:"content"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in); err != nil {
		http.Error(w, "JSON inválido", http.StatusBadRequest)
		return
	}
	in.Author = strings.TrimSpace(in.Author)
	in.Content = strings.TrimSpace(in.Content)
	if in.Author == "" || in.Content == "" {
		http.Error(w, "author e content são obrigatórios", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	var m Message
	err := s.pool.QueryRow(ctx,
		"INSERT INTO messages (author, content) VALUES ($1, $2) RETURNING id, author, content, created_at",
		in.Author, in.Content,
	).Scan(&m.ID, &m.Author, &m.Content, &m.CreatedAt)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start))
	})
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
