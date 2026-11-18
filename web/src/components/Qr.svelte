<script lang="ts">
  import QRCode from "qrcode";

  let { url, size = 360 }: { url: string; size?: number } = $props();
  let src = $state("");

  $effect(() => {
    let dead = false;
    QRCode.toDataURL(url, { margin: 1, width: size, errorCorrectionLevel: "M" }).then((s) => { if (!dead) src = s; });
    return () => { dead = true; };
  });
</script>

{#if src}<img {src} alt="QR code for {url}" width={size} height={size} style="max-width:100%;height:auto" />{/if}
