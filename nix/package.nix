# ArchType：fcitx5 插件 + 设置界面 + 自检工具 + 词库。
# 用法见 flake.nix 和 docs/INSTALL.md 的「NixOS / Nix」一节。
{
  lib,
  stdenv,
  fetchurl,
  rustPlatform,
  cargo,
  rustc,
  cmake,
  kdePackages,
  pkg-config,
  autoPatchelfHook,
  wrapGAppsHook4,
  gtk4,
  gtk4-layer-shell,
  webkitgtk_6_0,
  gst_all_1,
  libsoup_3,
  gsettings-desktop-schemas,
  fcitx5,
  alsa-lib,
}:

let
  # 版本号在根 Cargo.toml 的 [workspace.package]（各 crate 用 version.workspace = true，
  # 从 core/Cargo.toml 读会拿到 { workspace = true } 这个 set）
  version = (lib.importTOML ../Cargo.toml).workspace.package.version;

  # 词库不在 git 里：用发布页上的词库压缩包（scripts/package-deb.sh data 打的），按哈希固定。
  # 换了词库的版本发版后，发布流程会自动开 PR 改这三行（.github/scripts/nix-data-pr.sh）；
  # 手动改的话 hash 在发布页 SHA256SUMS 里，nix hash convert --hash-algo sha256 <十六进制> 转成 SRI 格式。
  dataVersion = "2026.11.11.8";
  data = fetchurl {
    url = "https://github.com/Goway-Hui/ArchType/releases/download/v0.6.2/archtype-data-rime-ice-${dataVersion}.tar.gz";
    hash = "sha256-hCYHF2XmmQji+RuZ8kWyl8lsgm/b+/kdZ+GPukTX84w=";
  };

  # 图形设置界面（NSH）：直接用发版时 CI 打好的包。版本单独记（和 dataVersion 一样）：
  # 包要发版之后才存在，跟着 ${version} 走的话一 bump 版本、发版那轮 Nix 任务就会去下
  # 还没上传的资产。发版后由 nix-data-pr.sh 的自动 PR 更新这三行。
  settingsVersion = "0.9.0";
  settingsAssets = {
    x86_64-linux = {
      url = "https://github.com/Goway-Hui/ArchType/releases/download/v${settingsVersion}/archtype-settings-nsh-${settingsVersion}-linux-x86_64.tar.gz";
      hash = "sha256-R9Rjp6IAC67kOIvOSWulziP+HFTClBNOV76tqohnWik=";
    };
    aarch64-linux = {
      url = "https://github.com/Goway-Hui/ArchType/releases/download/v${settingsVersion}/archtype-settings-nsh-${settingsVersion}-linux-aarch64.tar.gz";
      hash = "sha256-p+gRn/6vwTusSo/97MOvIGhUyeKfdTYugmSJ8tVmOHY=";
    };
  };
  settingsPackage = fetchurl settingsAssets.${stdenv.hostPlatform.system};

in
stdenv.mkDerivation {
  pname = "archtype";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../core
      ../voice
      ../voice-daemon
      ../cli
      ../net
      ../lexicon
      ../shell
      ../fcitx5-addon
      ../voice-overlay
      ../icons
      ../themes
      ../settings
      ../README.md
    ];
  };

  cargoDeps = rustPlatform.importCargoLock { lockFile = ../Cargo.lock; };


  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    cargo
    rustc
    cmake
    kdePackages.extra-cmake-modules
    pkg-config
    autoPatchelfHook
    wrapGAppsHook4
  ];

  buildInputs = [
    fcitx5
    alsa-lib
    gtk4
    gtk4-layer-shell
    webkitgtk_6_0
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    libsoup_3
    gsettings-desktop-schemas
  ];

  # 自检工具默认去 /usr/share/archtype 找词库，改成本包的目录
  postPatch = ''
    substituteInPlace core/src/bin/check.rs \
      --replace-fail /usr/share/archtype "$out/share/archtype"
  '';

  # 插件静态链接 Rust 核心、还要装 Rust 版 archtype-config：CMake 配置时两个产物都必须已经在
  preConfigure = ''
    cargo build --release --frozen --offline -p archtype-core -p archtype-config-cli
  '';

  cmakeDir = "../fcitx5-addon";
  cmakeFlags = [
    (lib.cmakeFeature "ARCHTYPE_VERSION" version)
    # fcitx5 的 CMake 配置里这个目录指向 fcitx5 自己的 store 路径，要装进本包
    (lib.cmakeFeature "FCITX_INSTALL_PKGDATADIR" "${placeholder "out"}/share/fcitx5")
  ];

  postInstall = ''
    rm -rf "$out/include"
    # 语音浮条（Wayland layer-shell）：非 GNOME 桌面（niri、sway 等）的「正在听…」浮条
    cmake -S ../voice-overlay -B build-voice -DCMAKE_BUILD_TYPE=Release
    cmake --build build-voice -j"''${NIX_BUILD_CORES:-2}"
    install -Dm755 build-voice/archtype-voice-overlay "$out/bin/archtype-voice-overlay"
    for bin in archtype-check archtype-show; do
      install -Dm755 "../target/release/$bin" "$out/bin/$bin"
    done

    mkdir -p data
    tar -xzf ${data} -C data
    install -Dm644 -t "$out/share/archtype" data/lexicon.tsv data/english.txt data/words.lm
    # 数据清单（docs/DATA.md「数据版本标记」）：REV=6 起的词库包里才有，钉的还是旧包时没有
    if [ -f data/DATA-MANIFEST ]; then
      install -Dm644 -t "$out/share/archtype" data/DATA-MANIFEST
    fi
    # 整句增强模型 nnlm.bin（ArchType 自己训的，CC BY-SA 4.0）：词库包是 package-deb.sh data 打的，
    # make-data.sh 下载到了模型的那次发版起包里才有它；钉的还是更早的包时没有，插件只是不做整句增强
    # （用户可以自己导入微信输入法的模型）。发版后 nix-data-pr.sh 换成新包，就自动带上
    if [ -f data/nnlm.bin ]; then
      install -Dm644 -t "$out/share/archtype" data/nnlm.bin
    fi
    install -Dm644 ../README.md "$out/share/doc/archtype/README.md"
    install -Dm644 data/SOURCE.txt "$out/share/doc/archtype/DATA-SOURCE.txt"
    echo ${dataVersion} > "$out/share/doc/archtype/DATA-VERSION"
    # 图形设置界面（NSH）：解到 lib/archtype/settings，桌面入口指向包装脚本
    mkdir -p "$out/lib/archtype/settings"
    tar -xzf ${settingsPackage} -C "$out/lib/archtype/settings" --strip-components=1
    runner=$(find "$out/lib/archtype/settings" -maxdepth 1 -type f -perm -u+x | head -1)
    if [ -z "$runner" ]; then
      echo "设置界面包里没有可执行文件（$out/lib/archtype/settings）" >&2
      exit 1
    fi
    cat > "$out/bin/archtype-settings" <<EOF
#!${stdenv.shell}
export XDG_DATA_DIRS="${gtk4}/share:${gsettings-desktop-schemas}/share:${webkitgtk_6_0}/share:\$XDG_DATA_DIRS"
exec "$out/lib/archtype/settings/$(basename "$runner")" "\$@"
EOF
    chmod 755 "$out/bin/archtype-settings"
    sed -i 's|^Exec=.*|Exec=archtype-settings|' \
      "$out/share/applications/io.github.GowayHui.ArchType.Config.desktop"
    install -Dm644 data/LICENSE "$out/share/licenses/archtype/LICENSE.rime-ice"
    # 五笔码表（rime-wubi，LGPL-3.0）：make-data.sh 的 REV=5 起，词库包里才有它。上面钉的还是旧包时没有它，
    # 设置里五笔灰掉；发版后 nix-data-pr.sh 换成新包，这个判断就总是成立
    if [ -f data/wubi86.tsv ]; then
      install -Dm644 -t "$out/share/archtype" data/wubi86.tsv
      install -Dm644 -t "$out/share/doc/archtype" data/WUBI-SOURCE.txt data/WUBI-AUTHORS
      install -Dm644 data/WUBI-LICENSE "$out/share/licenses/archtype/LICENSE.rime-wubi"
    fi

  '';

  passthru = {
    inherit data dataVersion;
  };

  meta = {
    description = "WeChat-style pinyin input method for fcitx5, with bundled dictionaries and language model";
    homepage = "https://github.com/Goway-Hui/ArchType";
    license = with lib.licenses; [
      mit
      asl20
      unicode-30
      gpl3Only # 词库（rime-ice）
      cc-by-sa-40 # 词级语言模型 words.lm、整句增强模型 nnlm.bin
      lgpl3Only # 五笔码表 wubi86.tsv（rime-wubi）
    ];
    # 设置界面的预编译包只有这两个架构（见上面的 settingsAssets）
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "archtype-config";
  };
}
