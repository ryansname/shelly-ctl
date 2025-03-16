{
  pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/4749dee2024acae748797cf619f54e451c858cd6.tar.gz") {} 
}: 

let 
in
pkgs.mkShell {
  nativeBuildInputs = [
  ];
  
  buildInputs = [
    pkgs.entr
  
    pkgs.git
    pkgs.zig
    pkgs.zls
  ];
}
