/**
 * Regenerates the sample documents shipped with the IDP examples.
 *
 * The examples need a real file to preview in `fileJsonReview`, and a real
 * file has to be a real PDF — so rather than committing a binary nobody can
 * diff, each document is described here as plain text and written out as a
 * minimal, dependency-free PDF 1.4 (Helvetica only, one page, no compression).
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

/** A line of the document: `text`, or `[label, value]` laid out in two columns. */
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
  }
];

/** PDF string literals escape the delimiters and backslash, nothing else. */
function escapeText(value) {
  return value.replace(/([\\()])/g, "\\$1");
}

function show(text, { size = 10, bold = false, x = MARGIN_X, y }) {
  return `BT /${bold ? "F2" : "F1"} ${size} Tf 1 0 0 1 ${x} ${y} Tm (${escapeText(text)}) Tj ET\n`;
}

/** Lays the line descriptors out top-down into a content stream. */
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
    stream += show(line.text, { size, bold: line.bold, y });
    y -= size + 6;
  }
  return stream;
}

/** Assembles objects into a PDF, computing the xref offsets as it goes. */
function buildPdf(lines) {
  const stream = contentStream(lines);
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_WIDTH} ${PAGE_HEIGHT}] ` +
      "/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>",
    `<< /Length ${Buffer.byteLength(stream, "latin1")} >>\nstream\n${stream}endstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
  ];

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
