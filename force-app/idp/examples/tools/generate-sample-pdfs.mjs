/**
 * Regenerates the sample documents shipped with the IDP examples.
 *
 * The examples need a real file to preview in `fileJsonReview`, and a real
 * file has to be a real PDF — so rather than committing a binary nobody can
 * diff, each document is described here as plain text and written out as a
 * minimal, dependency-free PDF 1.4 (Helvetica only, no compression). A
 * document paginates automatically once its lines run past the bottom
 * margin — add `{ pageBreak: true }` to force a break earlier (e.g. before
 * an annexure).
 *
 * Run from the repository root after editing a document:
 *
 *     node force-app/idp/examples/tools/generate-sample-pdfs.mjs
 *
 * Keep the text in step with the sample JSON next to each PDF: the whole
 * point of the examples is that what the reviewer sees on the left of
 * `fileJsonReview` matches what the mapping engine is fed on the right.
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXAMPLES_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const PAGE_WIDTH = 595;
const PAGE_HEIGHT = 842;
const MARGIN_X = 56;
const TOP_Y = 786;
const BOTTOM_Y = 56;

/**
 * A line of the document. One of:
 *   { text }       a run of text; `center: true` centres it, `x` places it
 *   { pair }       [label, value] laid out in two columns
 *   { columns }    cells at the fixed column stops
 *   { rule }       a horizontal rule
 *   { gap }        vertical space, in points
 *   { pageBreak }  forces a new page here, regardless of remaining space
 * `size` and `bold` apply to text, pair and column lines.
 */
const documents = [
  {
    path: "business-account-opening/documents/business-account-opening-application.pdf",
    lines: [
      { text: "MERIDIAN COMMERCIAL BANK", size: 15, bold: true },
      { text: "Business Account Opening Application", size: 11, bold: true },
      { gap: 10 },
      { rule: true },
      { gap: 12 },
      { text: "APPLICATION", size: 9, bold: true },
      { pair: ["Reference", "AO-2026-118842"] },
      { pair: ["Branch code", "0421"] },
      { pair: ["Product applied for", "Business Cheque Account"] },
      { pair: ["Date signed", "2026-07-14"] },
      { gap: 14 },
      { text: "APPLICANT ENTITY", size: 9, bold: true },
      { pair: ["Registered name", "Blue Harbour Trading"] },
      { pair: ["Registration number", "2018/447120/07"] },
      { pair: ["Tax reference", "9412887160"] },
      { pair: ["Date incorporated", "09/03/2018"] },
      { pair: ["Entity type", "Private Company"] },
      { pair: ["Annual turnover", "R 8 420 000.00"] },
      { pair: ["Telephone", "+27 21 555 0142"] },
      { gap: 14 },
      { text: "AUTHORISED SIGNATORY", size: 9, bold: true },
      { pair: ["Full name", "Thandi Mokoena"] },
      { pair: ["Capacity", "Managing Director"] },
      { pair: ["Email", "thandi.mokoena@blueharbour.example.com"] },
      { gap: 14 },
      { text: "NOTES", size: 9, bold: true },
      {
        text: "Applicant requests an overdraft facility review after six months"
      },
      { text: "of account conduct." },
      { gap: 24 },
      { rule: true },
      { gap: 12 },
      {
        text: "Sample document for demonstration purposes only. Not a real institution.",
        size: 8
      }
    ]
  },
  {
    path: "consolidated-statement/documents/consolidated-statement.pdf",
    lines: [
      { text: "MERIDIAN COMMERCIAL BANK", size: 15, bold: true },
      { text: "Consolidated Statement of Accounts", size: 11, bold: true },
      { gap: 10 },
      { rule: true },
      { gap: 12 },
      { pair: ["Statement number", "CS-2026-07-0098"] },
      { pair: ["Period ended", "2026-07-31"] },
      { pair: ["Customer", "Cape Meridian Logistics"] },
      { pair: ["Customer number", "CUS-4471203"] },
      { pair: ["Total relationship balance", "R 1 284 730.55"] },
      { gap: 16 },
      { text: "PRODUCTS HELD", size: 9, bold: true },
      { gap: 4 },
      { columns: ["Account number", "Product", "Balance", "Rate", "Status"] },
      { rule: true },
      {
        columns: [
          "62110044721",
          "Business Cheque Account",
          "184 230.55",
          "0.25",
          "Active"
        ]
      },
      {
        columns: [
          "90071188420",
          "Business Call Deposit",
          "950 000.00",
          "7.15",
          "Active"
        ]
      },
      {
        columns: [
          "45500219873",
          "Business Credit Card",
          "-32 500.00",
          "18.75",
          "In Arrears"
        ]
      },
      {
        columns: [
          "77012004466",
          "Vehicle Asset Finance",
          "183 000.00",
          "11.50",
          "Closed"
        ]
      },
      { rule: true },
      { gap: 14 },
      { text: "Opened dates: 09/03/2018, 22/06/2021, 14/11/2022, 03/02/2023" },
      { gap: 24 },
      { rule: true },
      { gap: 12 },
      {
        text: "Sample document for demonstration purposes only. Not a real institution.",
        size: 8
      }
    ]
  },
  {
    path: "loan-offer-compliance/documents/loan-offer-letter.pdf",
    lines: [
      { text: "MERIDIAN COMMERCIAL BANK", size: 15, bold: true },
      {
        text: "Business Term Loan - Signed Offer Letter",
        size: 11,
        bold: true
      },
      { gap: 10 },
      { rule: true },
      { gap: 12 },
      { text: "BORROWER", size: 9, bold: true },
      { pair: ["Registered name", "KALAHARI FREIGHT SERVICES"] },
      { pair: ["Credit risk grade", "BB"] },
      { pair: ["Verified annual turnover", "R 14 750 000.00"] },
      { gap: 14 },
      { text: "OFFER TERMS", size: 9, bold: true },
      { pair: ["Offer reference", "LN-2026-093315"] },
      { pair: ["Principal amount", "R 2 400 000.00"] },
      { pair: ["Interest rate", "12.05 %"] },
      { pair: ["Term", "60 months"] },
      { pair: ["Monthly repayment", "R 53 480.19"] },
      { pair: ["Offer expires", "31/08/2026"] },
      { gap: 20 },
      {
        text: "The borrower accepts the terms set out above and confirms that the"
      },
      {
        text: "particulars recorded in this letter are correct as at the date of signature."
      },
      { gap: 26 },
      { text: "_______________________________", size: 10 },
      { text: "For and on behalf of the borrower", size: 9 },
      { gap: 24 },
      { rule: true },
      { gap: 12 },
      {
        text: "Sample document for demonstration purposes only. Not a real institution.",
        size: 8
      }
    ]
  },
  {
    // A stand-in for the J238 Letters of Executorship issued by the Master of
    // the High Court. Deliberately marked SPECIMEN top and bottom, with
    // fictitious names and identity numbers: it is a fixture for the mapping
    // example, and must never be mistakable for an issued legal instrument.
    path: "letters-of-executorship/documents/letters-of-executorship.pdf",
    lines: [
      { columns: ["G.P.-S 003-0317", "", "", "", "J238"] },
      { gap: 6 },
      {
        text: "SPECIMEN - SAMPLE DOCUMENT FOR SYSTEM DEMONSTRATION ONLY",
        size: 8,
        bold: true,
        center: true
      },
      {
        text: "Not issued by any court or government body. All names and numbers are fictitious.",
        size: 8,
        center: true
      },
      { gap: 10 },
      { rule: true },
      { gap: 12 },
      {
        text: "REPUBLIC OF SOUTH AFRICA",
        size: 11,
        bold: true,
        center: true
      },
      { gap: 16 },
      { text: "LETTERS OF EXECUTORSHIP", size: 16, bold: true, center: true },
      { gap: 6 },
      {
        text: "(Section 13 and 14 of the Administration of Estates Act, No 66 of 1965)",
        size: 9,
        center: true
      },
      { gap: 26 },
      { pair: ["Estate No:", "007842/2027"] },
      { gap: 18 },
      { text: "THIS IS TO CERTIFY that", size: 11, bold: true, center: true },
      { gap: 16 },
      { text: "JOHAN COENRAAD STEYN", size: 13, bold: true, center: true },
      { gap: 4 },
      { text: "Identity no: 7205125123086", size: 10, center: true },
      { gap: 10 },
      {
        text: "ADRIANA MAGDALENA BOTHA",
        size: 13,
        bold: true,
        center: true
      },
      { gap: 4 },
      { text: "Identity no: 6803210456082", size: 10, center: true },
      { gap: 20 },
      { text: "has/have been duly appointed", size: 10, center: true },
      { gap: 14 },
      { text: "EXECUTORS", size: 12, bold: true, center: true },
      { gap: 18 },
      {
        text: "and is/are hereby authorised as such to liquidate and distribute the Estate of the late",
        size: 9,
        center: true
      },
      { gap: 20 },
      { text: "GIDEON PETRUS BOTHA", size: 13, bold: true, center: true },
      { gap: 18 },
      { pair: ["Identity No:", "5606125678089"] },
      { pair: ["who died on:", "12/11/2026"] },
      { gap: 24 },
      { rule: true },
      { gap: 12 },
      { text: "Asst. Master of the High Court", size: 10, bold: true },
      { gap: 4 },
      { pair: ["Master's Office:", "Bloemfontein"] },
      { pair: ["Datum gestempel / Date stamped:", "1 Maart 2027"] },
      { gap: 12 },
      {
        text: "Attention is directed to the provisions of section 102.",
        size: 9
      },
      { gap: 8 },
      { rule: true },
      { gap: 10 },
      {
        text: "DEPARTMENT OF JUSTICE AND CONSTITUTIONAL DEVELOPMENT",
        size: 8
      },
      { gap: 8 },
      {
        text: "SPECIMEN - not a valid legal document. Generated for the Salesforce IDP examples.",
        size: 8,
        bold: true
      },

      { pageBreak: true },

      {
        text: "SPECIMEN - SAMPLE DOCUMENT FOR SYSTEM DEMONSTRATION ONLY",
        size: 8,
        bold: true,
        center: true
      },
      { gap: 10 },
      {
        text: "ANNEXURE A: RELATED PARTIES",
        size: 13,
        bold: true,
        center: true
      },
      { gap: 4 },
      {
        text: "Estate No: 007842/2027 - Estate Late G P Botha",
        size: 9,
        center: true
      },
      { gap: 14 },
      { rule: true },
      { gap: 12 },

      { text: "EXECUTOR - Johan Coenraad Steyn", size: 10, bold: true },
      { pair: ["Identity No:", "7205125123086"] },
      { pair: ["Contact:", "+27 51 522 1000"] },
      { pair: ["Address:", "14 President Boulevard, Bloemfontein, 9301"] },
      { gap: 10 },

      { text: "EXECUTOR - Adriana Magdalena Botha", size: 10, bold: true },
      { pair: ["Identity No:", "6803210456082"] },
      { pair: ["Contact:", "051 522 1000"] },
      { pair: ["Address:", "22 Vaal Street, Bloemfontein, 9301"] },
      { gap: 10 },

      { text: "SPOUSE - Petra Elizabeth Botha", size: 10, bold: true },
      { pair: ["Identity No:", "6205300234083"] },
      { pair: ["Contact:", "082 555 1234"] },
      { pair: ["Address:", "22 Vaal Street, Bloemfontein, 9301"] },
      { gap: 10 },

      { text: "HEIR - Marnus Botha", size: 10, bold: true },
      { pair: ["Identity No:", "9202155123081"] },
      { pair: ["Contact:", "(011) 234 5678"] },
      { pair: ["Address:", "8 Kloof Road, Sandton, 2196"] },
      { gap: 10 },

      { text: "HEIR - Lindiwe Botha", size: 10, bold: true },
      { pair: ["Identity No:", "(none - foreign heir)"] },
      { pair: ["Contact:", "(none on file)"] },
      {
        pair: [
          "Address:",
          "Flat 4, Riverside Court, 221 High Street, Manchester, M1 4EX, UK"
        ]
      },
      { gap: 10 },

      {
        text: "ATTORNEY - Adv. Karin Nel (Van Wyk & Steyn Attorneys)",
        size: 10,
        bold: true
      },
      { pair: ["Identity No:", "(firm - not applicable)"] },
      { pair: ["Contact:", "011-234-5678"] },
      { pair: ["Address:", "PO Box 445, Kimberley, 8300"] },
      { gap: 14 },

      { rule: true },
      { gap: 10 },
      {
        text: "Estate reference (repeated): EST No. 007842 / 2027",
        size: 8
      },
      { gap: 8 },
      {
        text: "SPECIMEN - not a valid legal document. Generated for the Salesforce IDP examples.",
        size: 8,
        bold: true
      }
    ]
  }
];

/** PDF string literals escape the delimiters and backslash, nothing else. */
function escapeText(value) {
  return value.replace(/([\\()])/g, "\\$1");
}

function show(text, { size = 10, bold = false, x = MARGIN_X, y }) {
  return `BT /${bold ? "F2" : "F1"} ${size} Tf 1 0 0 1 ${x} ${y} Tm (${escapeText(text)}) Tj ET\n`;
}

/**
 * Average Helvetica advance width as a fraction of the font size. Only used
 * to centre a line, where being a few points out is invisible — the sample
 * documents have no justified text that would need real glyph metrics.
 */
const AVG_CHAR_WIDTH = { regular: 0.5, bold: 0.55 };

function centeredX(text, size, bold) {
  const width =
    text.length * size * (bold ? AVG_CHAR_WIDTH.bold : AVG_CHAR_WIDTH.regular);
  return Math.max(MARGIN_X, Math.round((PAGE_WIDTH - width) / 2));
}

/** The vertical space a line descriptor takes, mirroring contentStream's own bookkeeping. */
function lineHeight(line) {
  if (line.gap !== undefined) return line.gap;
  if (line.rule) return 14; // 4pt before the rule, 10pt after
  if (line.columns) return 15;
  if (line.pair) return 16;
  return (line.size ?? 10) + 6;
}

/**
 * Splits the document's line descriptors into pages, breaking whenever the
 * next line would cross the bottom margin (or on an explicit `pageBreak`).
 */
function paginate(lines) {
  const pages = [];
  let current = [];
  let y = TOP_Y;

  for (const line of lines) {
    if (line.pageBreak) {
      if (current.length > 0) pages.push(current);
      current = [];
      y = TOP_Y;
      continue;
    }
    const height = lineHeight(line);
    if (y - height < BOTTOM_Y && current.length > 0) {
      pages.push(current);
      current = [];
      y = TOP_Y;
    }
    current.push(line);
    y -= height;
  }
  if (current.length > 0) pages.push(current);
  return pages;
}

/** Lays one page's line descriptors out top-down into a content stream. */
function contentStream(lines) {
  const COLUMN_X = [MARGIN_X, 176, 330, 424, 480];
  let y = TOP_Y;
  let stream = "";
  for (const line of lines) {
    if (line.gap !== undefined) {
      y -= line.gap;
      continue;
    }
    if (line.rule) {
      y -= 4;
      stream += `0.6 w ${MARGIN_X} ${y} m ${PAGE_WIDTH - MARGIN_X} ${y} l S\n`;
      y -= 10;
      continue;
    }
    if (line.columns) {
      line.columns.forEach((cell, index) => {
        stream += show(cell, { size: 9, x: COLUMN_X[index], y });
      });
      y -= 15;
      continue;
    }
    if (line.pair) {
      stream += show(line.pair[0], { size: 10, y });
      stream += show(line.pair[1], { size: 10, bold: true, x: 232, y });
      y -= 16;
      continue;
    }
    const size = line.size ?? 10;
    const x = line.center
      ? centeredX(line.text, size, line.bold)
      : (line.x ?? MARGIN_X);
    stream += show(line.text, { size, bold: line.bold, x, y });
    y -= size + 6;
  }
  return stream;
}

/** Assembles objects into a PDF, computing the xref offsets as it goes. */
function buildPdf(lines) {
  const pages = paginate(lines);
  const numPages = pages.length;
  // Object numbers: 1 Catalog, 2 Pages, then a (Page, Contents) pair per
  // page, then the two shared Font objects. With one page this numbers
  // exactly as before: 1 Catalog, 2 Pages, 3 Page, 4 Contents, 5 F1, 6 F2.
  const f1Index = 3 + numPages * 2;
  const f2Index = f1Index + 1;

  const objects = new Array(2 + numPages * 2 + 2);
  objects[0] = "<< /Type /Catalog /Pages 2 0 R >>";
  const kids = pages.map((_, index) => `${3 + index * 2} 0 R`);
  objects[1] = `<< /Type /Pages /Kids [${kids.join(" ")}] /Count ${numPages} >>`;

  pages.forEach((pageLines, index) => {
    const stream = contentStream(pageLines);
    const pageObjNum = 3 + index * 2;
    const contentsObjNum = pageObjNum + 1;
    objects[pageObjNum - 1] =
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_WIDTH} ${PAGE_HEIGHT}] ` +
      `/Resources << /Font << /F1 ${f1Index} 0 R /F2 ${f2Index} 0 R >> >> /Contents ${contentsObjNum} 0 R >>`;
    objects[contentsObjNum - 1] =
      `<< /Length ${Buffer.byteLength(stream, "latin1")} >>\nstream\n${stream}endstream`;
  });

  objects[f1Index - 1] =
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>";
  objects[f2Index - 1] =
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>";

  let pdf = "%PDF-1.4\n";
  const offsets = [];
  objects.forEach((body, index) => {
    offsets.push(Buffer.byteLength(pdf, "latin1"));
    pdf += `${index + 1} 0 obj\n${body}\nendobj\n`;
  });

  const startxref = Buffer.byteLength(pdf, "latin1");
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets) {
    pdf += `${String(offset).padStart(10, "0")} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n`;
  pdf += `startxref\n${startxref}\n%%EOF\n`;
  return Buffer.from(pdf, "latin1");
}

for (const document of documents) {
  const target = join(EXAMPLES_DIR, document.path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, buildPdf(document.lines));
  console.log(`wrote ${document.path}`);
}
