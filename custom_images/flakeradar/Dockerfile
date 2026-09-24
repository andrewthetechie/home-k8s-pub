# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Clone the pinned flakeradar revision once; both build stages pull from here.
# Pass the commit to build with:
#   docker build --build-arg FLAKERADAR_SHA=<commit-sha> -t flakeradar .
# ---------------------------------------------------------------------------
FROM alpine/git:latest AS src
ARG FLAKERADAR_SHA=c4fa75ad796b6184403d3b2f9fb41c9851d6f57a
RUN git init /repo \
    && cd /repo \
    && git remote add origin https://github.com/manijose1919/flakeradar \
    && git fetch --depth 1 origin "${FLAKERADAR_SHA}" \
    && git checkout FETCH_HEAD

# ---------------------------------------------------------------------------
# Build the frontend (vite -> dist/).
# ---------------------------------------------------------------------------
FROM node:22-slim AS frontend
WORKDIR /build
COPY --from=src /repo/frontend/package.json /repo/frontend/package-lock.json* ./
RUN npm install
COPY --from=src /repo/frontend/ ./
RUN npm run build

# ---------------------------------------------------------------------------
# Backend runtime.
# ---------------------------------------------------------------------------
FROM python:3.12-slim

# Mirror the repo layout: main.py resolves ../../frontend/dist from app/.
WORKDIR /srv/backend
COPY --from=src /repo/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=src /repo/backend/app ./app
COPY --from=src /repo/backend/alembic.ini .
COPY --from=src /repo/backend/migrations ./migrations
COPY --from=frontend /build/dist /srv/frontend/dist
RUN mkdir -p /srv/backend/data

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
