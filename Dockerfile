FROM elixir:latest

RUN apt-get update && \
apt-get -y install sudo bash curl build-essential

ADD . /app

ENV MIX_ENV=prod PHX_HOST=localhost PHX_SERVER=true DATABASE_PATH=stage3_queue_prod.db SECRET_KEY_BASE=qweqweqwe

RUN mix local.hex --force \
&& mix local.rebar --force
# RUN mix archive.install hex phx_new

WORKDIR /app

RUN mix deps.get

RUN mix compile

EXPOSE 4000

CMD ["mix", "clean"]
CMD ["mix", "ecto.setup"]
CMD ["mix", "phx.server"]
