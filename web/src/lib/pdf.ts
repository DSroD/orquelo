import * as pdfjs from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

export type PdfDoc = pdfjs.PDFDocumentProxy;

const open = (src: string | ArrayBuffer): Promise<PdfDoc> =>
  pdfjs.getDocument(typeof src === "string" ? { url: src } : { data: new Uint8Array(src) }).promise;

// One parsed document per URL: thumbnails and the cockpit share it instead of each fetching the PDF again.
const byUrl = new Map<string, Promise<PdfDoc>>();
export function loadPdf(src: string | ArrayBuffer): Promise<PdfDoc> {
  if (typeof src !== "string") return open(src);
  let doc = byUrl.get(src);
  if (!doc) {
    doc = open(src);
    doc.catch(() => byUrl.delete(src));
    byUrl.set(src, doc);
  }
  return doc;
}

export async function pageCountOf(file: File): Promise<number> {
  const doc = await loadPdf(await file.arrayBuffer());
  const n = doc.numPages;
  void doc.destroy();
  return n;
}
