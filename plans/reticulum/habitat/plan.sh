pkg_name=reticulum
pkg_origin=raspberry-dream-labs
pkg_version="1.0.1"
pkg_maintainer="Raspberry Dream Labs (info@rasberrydreamlabs.com)"
pkg_source="https://github.com/Raspberry-Dream-Land/reticulum"
pkg_upstream_url="https://github.com/Raspberry-Dream-Land/reticulum/"
pkg_license=('MPL-2.0')
pkg_filename="reticulum-1.0.1.tar.bz2"
pkg_branch="polycosm"

pkg_deps=(
    core/coreutils/8.30/20190115012313
    core/bash/4.4.19/20190115012619
    core/which/2.21/20190430084037
    raspberry-dream-labs/erlang/22.0
)

pkg_build_deps=(
    core/coreutils/8.30/20190115012313
    core/git/2.26.2/20200601121014
    raspberry-dream-labs/erlang/22.0
    raspberry-dream-labs/elixir/1.8.0
)

pkg_exports=(
   [port]=phx.port
)

pkg_description="A moral imperative."

do_download() {
  export GIT_SSL_NO_VERIFY=true
  rm -rf ./reticulum*
  git clone --branch $pkg_branch $pkg_source
  mv ./reticulum ./reticulum-1.0.1
  tar -cjvf $HAB_CACHE_SRC_PATH/$pkg_filename ./reticulum-1.0.1 --exclude reticulum/.git --exclude reticulum/spec
}

do_verify() {
    return 0
}

do_prepare() {
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export MIX_ENV=prod
    export RELEASE_VERSION="1.0.$(echo $pkg_prefix | cut -d '/' -f 7)" 

    # Rebar3 will hate us otherwise because it looks for
    # /usr/bin/env when it does some of its compiling
    [[ ! -f /usr/bin/env ]] && ln -s "$(pkg_path_for coreutils)/bin/env" /usr/bin/env

    return 0
}

do_build() {
    mix local.hex --force
    mix local.rebar --force
    mix deps.get --only prod
    mix deps.clean mime --build
    rm -rf _build
    mix compile
}

do_install() {
    rm -rf _build/prod/rel/ret/releases
    MIX_ENV=prod mix distillery.release
    # TODO 1.9 releases chmod 0655 _build/prod/rel/ret/bin/*
    cp -a _build/prod/rel/ret/* ${pkg_prefix}

    for f in $(find ${pkg_prefix} -name '*.sh')
    do
        fix_interpreter "$f" core/bash bin/bash
        fix_interpreter "$f" core/coreutils bin/env
        # TODO 1.9 releases chmod 0655 "$f"
    done

    # TODO 1.9 releases chmod 0655 elixir, bin/erl
}

do_strip() {
    return 0
}

do_end() {
    return 0
}

