# ci.project-url: https://github.com/matrix-org/synapse
# ci.test-command: python -m synapse.app.homeserver --server-name local -c homeserver.yaml --generate-config --report-stats=no
{ pkgs, ... }:

{
  # Configure packages to install.
  # Search for package names at https://search.nixos.org/packages?channel=unstable
  packages = with pkgs; [
    # The rust toolchain and related tools.
    # This will install the "default" profile of rust components.
    # https://rust-lang.github.io/rustup/concepts/profiles.html
    #
    # NOTE: We currently need to set the Rust version unnecessarily high
    # in order to work around https://github.com/matrix-org/synapse/issues/15939
    (rust-bin.stable."1.71.1".default.override {
      # Additionally install the "rust-src" extension to allow diving into the
      # Rust source code in an IDE (rust-analyzer will also make use of it).
      extensions = [ "rust-src" ];
    })
    # The rust-analyzer language server implementation.
    rust-analyzer

    # GCC includes a linker; needed for building `ruff`
    gcc
    # Needed for building `ruff`
    gnumake
    libiconvReal

    # Native dependencies for running Synapse.
    icu
    libffi
    libjpeg
    libpqxx
    libwebp
    libxml2
    libxslt
    sqlite

    # Native dependencies for unit tests.
    openssl
    xmlsec

    # For building the Synapse documentation website.
    mdbook

    # For releasing Synapse
    debian-devscripts # (`dch` for manipulating the Debian changelog)
    libnotify # (the release script uses `notify-send` to tell you when CI jobs are done)
  ];

  # Install Python and manage a virtualenv with Poetry.
  languages.python.enable = true;
  languages.python.poetry.enable = true;
  # Automatically activate the poetry virtualenv upon entering the shell.
  languages.python.poetry.activate.enable = true;
  # Install all extra Python dependencies; this is needed to run the unit
  # tests and utilitise all Synapse features.
  languages.python.poetry.install.arguments = ["--extras all"];
  # Install the 'matrix-synapse' package from the local checkout.
  languages.python.poetry.install.installRootPackage = true;

  # This is a work-around for NixOS systems. NixOS is special in
  # that you can have multiple versions of packages installed at
  # once, including your libc linker!
  #
  # Some binaries built for Linux expect those to be in a certain
  # filepath, but that is not the case on NixOS. In that case, we
  # force compiling those binaries locally instead.
  env.POETRY_INSTALLER_NO_BINARY = "ruff";

  # Postgres is needed to run Synapse with postgres support and
  # to run certain unit tests that require postgres.
  services.postgres.enable = true;

  # On the first invocation of `devenv up`, create a database for
  # Synapse to store data in.
  services.postgres.initdbArgs = ["--locale=C" "--encoding=UTF8"];
  services.postgres.initialDatabases = [
    { name = "synapse"; }
  ];
  # Create a postgres user called 'synapse_user' which has ownership
  # over the 'synapse' database.
  services.postgres.initialScript = ''
  CREATE USER synapse_user;
  ALTER DATABASE synapse OWNER TO synapse_user;
  '';

  # Redis is needed in order to run Synapse in worker mode.
  services.redis.enable = true;

  # Configure and start Synapse. Before starting Synapse, this shell code:
  #  * generates a default homeserver.yaml config file if one does not exist, and
  #  * ensures a directory containing two additional homeserver config files exists;
  #    one to configure using the development environment's PostgreSQL as the
  #    database backend and another for enabling Redis support.
  process.before = ''
    python -m synapse.app.homeserver -c homeserver.yaml --generate-config --server-name=synapse.dev --report-stats=no
    mkdir -p homeserver-config-overrides.d
    cat > homeserver-config-overrides.d/database.yaml << EOF
    ## Do not edit this file. This file is generated by flake.nix
    database:
      name: psycopg2
      args:
        user: synapse_user
        database: synapse
        host: $PGHOST
        cp_min: 5
        cp_max: 10
    EOF
    cat > homeserver-config-overrides.d/redis.yaml << EOF
    ## Do not edit this file. This file is generated by flake.nix
    redis:
      enabled: true
    EOF
  '';
  # Start synapse when `devenv up` is run.
  # We set LD_LIBRARY_PATH to counteract the unsetting below,
  # so that Synapse has the libs that it needs.
  processes.synapse.exec = "LD_LIBRARY_PATH=$DEVENV_ROOT/.devenv/profile/lib poetry run python -m synapse.app.homeserver -c homeserver.yaml -c homeserver-config-overrides.d";

  # Clear the LD_LIBRARY_PATH environment variable on shell init.
  #
  # By default, devenv will set LD_LIBRARY_PATH to point to .devenv/profile/lib. This causes
  # issues when we include `gcc` as a dependency to build C libraries, as the version of glibc
  # that the development environment's cc compiler uses may differ from that of the system.
  #
  # When LD_LIBRARY_PATH is set, system tools will attempt to use the development environment's
  # libraries. Which, when built against a different glibc version lead, to "version 'GLIBC_X.YY'
  # not found" errors.
  enterShell = ''
    unset LD_LIBRARY_PATH
  '';
}