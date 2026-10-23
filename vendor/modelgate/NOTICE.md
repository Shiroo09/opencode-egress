# vendor/modelgate

- Ürün adı: **modelgate** (proje içinde bu adla anılır).
- Kaynak: https://github.com/12errh/zen-proxy (MIT, LICENSE bu dizinde)
- Vendor tarihi: 2026-10-22 (main dalı, shallow); dizin 2026-10-23'te `vendor/zen-proxy` → `vendor/modelgate` olarak yeniden adlandırıldı.
- Dosya adları (`zen-proxy.mjs`, `zen-proxy.json`, `bin/claude-zen*`) upstream'den geldiği gibi bırakıldı — güncelleme diff'i bozulmasın.
- Güncelleme: `git clone --depth 1 https://github.com/12errh/zen-proxy /tmp/z && git -C /tmp/z archive HEAD | tar -x -C vendor/modelgate`

models.json upstream'te GitHub Action ile 6 saatte bir tazelenir; güncellemek için yukarıdaki komutu tekrarla.
