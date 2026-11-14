{
  lib,
  stdenvNoCC,
  llvmPackages,
  libbpf,
  ebpf-headers,
}:
stdenvNoCC.mkDerivation {
  pname = "relocatable-shebang";
  version = "0.1.0";
  src = ./relocate.bpf.c;
  dontUnpack = true;
  nativeBuildInputs = [ llvmPackages.clang-unwrapped ];
  buildPhase = ''
    clang -g -O2 -target bpf -mcpu=v3 -DBPF_NO_KFUNC_PROTOTYPES \
      -I${ebpf-headers} -I${lib.getDev libbpf}/include \
      -c "$src" -o relocate.bpf.o
  '';
  installPhase = ''
    install -Dm444 relocate.bpf.o $out/lib/bpf/relocate.bpf.o
  '';
  dontStrip = true;
  meta.license = lib.licenses.gpl2Only;
  meta.platforms = lib.platforms.linux;
}
