export type PdfOptions = { pages?: number; padTo?: number };

// A valid PDF with one "Slide N" page each (320x180, Helvetica) and a correct xref;
// padTo adds an uncompressed filler stream so the file reaches about that many bytes.
export function makePdf({ pages = 3, padTo = 0 }: PdfOptions = {}): Buffer {
  const objs: string[] = [];
  const kids = Array.from({ length: pages }, (_, i) => `${4 + 2 * i} 0 R`).join(" ");
  objs.push("<< /Type /Catalog /Pages 2 0 R >>");
  objs.push(`<< /Type /Pages /Kids [${kids}] /Count ${pages} >>`);
  objs.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
  for (let i = 0; i < pages; i++) {
    objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 180] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + 2 * i} 0 R >>`);
    objs.push(stream(`BT /F1 36 Tf 60 80 Td (Slide ${i + 1}) Tj ET`));
  }
  const base = render(objs).length;
  if (padTo > base) objs.push(stream("%".repeat(padTo - base - 60)));
  return render(objs);
}

const stream = (body: string): string => `<< /Length ${body.length} >>\nstream\n${body}\nendstream`;

function render(objs: string[]): Buffer {
  let out = "%PDF-1.4\n";
  const offsets = objs.map((o, i) => {
    const at = out.length;
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
    return at;
  });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  out += offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("");
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, "latin1");
}
