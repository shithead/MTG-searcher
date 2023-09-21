# shell.nix
{ pkgs ? import <nixpkgs> {} }:
with pkgs;
let
  my-perl = perl;
  perl-with-my-packages = my-perl.withPackages (p: with p; [
    DBI
    NetSSLeay
    CryptPBKDF2    
    Mojolicious
    DataPrinter
    TextCSV
    DBDSQLite
    IOSocketSSL
  ]);
  
in
pkgs.mkShell {
  name = "perlzone";
  buildInputs = [
    gcc
    pkg-config
    glibc.dev
    perl-with-my-packages
  ];
  nativeBuildInputs = [
    makeWrapper
  ];
  PERL5LIB = with perlPackages; makeFullPerlPath [ DBI NetSSLeay CryptPBKDF2 Mojolicious DataPrinter TextCSV DBDSQLite IOSocketSSL ] ;
    
  shellHook = ''
  '';
}
