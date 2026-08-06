/**
 * Generates the IDP_Country__mdt and IDP_Language__mdt seed records.
 *
 *   node force-app/idp/scripts/seed-locale-metadata.mjs
 *
 * The tables below are the source of truth; the .md-meta.xml files are
 * generated output, committed so a plain `sf project deploy` ships them.
 * Onboarding a country is a line in COUNTRIES and a rerun — or, in a live
 * org, one record created in Setup. Neither is a code release.
 *
 * Month names: twelve pipe-separated entries in order, January first. An
 * entry may list comma-separated spellings, the first being canonical —
 * for inflected forms that are not prefixes of the nominative (Polish
 * "stycznia", Czech "ledna") and for abbreviations that are not either
 * (German "Mrz"). Matching in IdpLocaleData is accent- and case-blind, so
 * "März" needs no "Marz" alias but does need "Maerz".
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '..', 'main', 'default', 'customMetadata');

// code | label | dial code | decimal separator
const COUNTRIES = `
ZA|South Africa|27|,
NG|Nigeria|234|.
KE|Kenya|254|.
GH|Ghana|233|.
EG|Egypt|20|.
MA|Morocco|212|,
TZ|Tanzania|255|.
UG|Uganda|256|.
ZM|Zambia|260|.
ZW|Zimbabwe|263|.
BW|Botswana|267|.
NA|Namibia|264|,
MZ|Mozambique|258|,
LS|Lesotho|266|,
SZ|Eswatini|268|,
MW|Malawi|265|.
ET|Ethiopia|251|.
CI|Cote d'Ivoire|225|,
SN|Senegal|221|,
CM|Cameroon|237|,
GB|United Kingdom|44|.
IE|Ireland|353|.
DE|Germany|49|,
FR|France|33|,
NL|Netherlands|31|,
BE|Belgium|32|,
LU|Luxembourg|352|,
ES|Spain|34|,
PT|Portugal|351|,
IT|Italy|39|,
CH|Switzerland|41|.
AT|Austria|43|,
SE|Sweden|46|,
NO|Norway|47|,
DK|Denmark|45|,
FI|Finland|358|,
IS|Iceland|354|,
PL|Poland|48|,
CZ|Czechia|420|,
SK|Slovakia|421|,
HU|Hungary|36|,
RO|Romania|40|,
BG|Bulgaria|359|,
GR|Greece|30|,
HR|Croatia|385|,
SI|Slovenia|386|,
RS|Serbia|381|,
UA|Ukraine|380|,
TR|Turkiye|90|,
RU|Russia|7|,
LT|Lithuania|370|,
LV|Latvia|371|,
EE|Estonia|372|,
CY|Cyprus|357|.
MT|Malta|356|.
US|United States|1|.
CA|Canada|1|.
MX|Mexico|52|.
BR|Brazil|55|,
AR|Argentina|54|,
CL|Chile|56|,
CO|Colombia|57|,
PE|Peru|51|.
UY|Uruguay|598|,
PA|Panama|507|.
AU|Australia|61|.
NZ|New Zealand|64|.
IN|India|91|.
CN|China|86|.
JP|Japan|81|.
KR|South Korea|82|.
SG|Singapore|65|.
HK|Hong Kong SAR|852|.
TW|Taiwan|886|.
MY|Malaysia|60|.
TH|Thailand|66|.
ID|Indonesia|62|,
PH|Philippines|63|.
VN|Vietnam|84|,
PK|Pakistan|92|.
BD|Bangladesh|880|.
LK|Sri Lanka|94|.
AE|United Arab Emirates|971|.
SA|Saudi Arabia|966|.
QA|Qatar|974|.
KW|Kuwait|965|.
BH|Bahrain|973|.
OM|Oman|968|.
IL|Israel|972|.
JO|Jordan|962|.
LB|Lebanon|961|.
`;

// code | label | decimal separator | twelve months, January first
const LANGUAGES = `
en|English|.|January|February|March|April|May|June|July|August|September|October|November|December
af|Afrikaans|,|Januarie|Februarie|Maart|April|Mei|Junie|Julie|Augustus|September|Oktober|November|Desember
de|German|,|Januar|Februar|März,Maerz,Mrz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember
nl|Dutch|,|januari|februari|maart|april|mei|juni|juli|augustus|september|oktober|november|december
fr|French|,|janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre
es|Spanish|,|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre,setiembre|octubre|noviembre|diciembre
pt|Portuguese|,|janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro
it|Italian|,|gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre
sv|Swedish|,|januari|februari|mars|april|maj|juni|juli|augusti|september|oktober|november|december
no|Norwegian|,|januar|februar|mars|april|mai|juni|juli|august|september|oktober|november|desember
da|Danish|,|januar|februar|marts|april|maj|juni|juli|august|september|oktober|november|december
fi|Finnish|,|tammikuu,tammikuuta|helmikuu,helmikuuta|maaliskuu,maaliskuuta|huhtikuu,huhtikuuta|toukokuu,toukokuuta|kesäkuu,kesäkuuta|heinäkuu,heinäkuuta|elokuu,elokuuta|syyskuu,syyskuuta|lokakuu,lokakuuta|marraskuu,marraskuuta|joulukuu,joulukuuta
pl|Polish|,|styczeń,stycznia|luty,lutego|marzec,marca|kwiecień,kwietnia|maj,maja|czerwiec,czerwca|lipiec,lipca|sierpień,sierpnia|wrzesień,września|październik,października|listopad,listopada|grudzień,grudnia
cs|Czech|,|leden,ledna|únor,února|březen,března|duben,dubna|květen,května|červen,června|červenec,července|srpen,srpna|září|říjen,října|listopad,listopadu|prosinec,prosince
hu|Hungarian|,|január|február|március|április|május|június|július|augusztus|szeptember|október|november|december
ro|Romanian|,|ianuarie|februarie|martie|aprilie|mai|iunie|iulie|august|septembrie|octombrie|noiembrie|decembrie
el|Greek|,|Ιανουάριος,Ιανουαρίου|Φεβρουάριος,Φεβρουαρίου|Μάρτιος,Μαρτίου|Απρίλιος,Απριλίου|Μάιος,Μαΐου|Ιούνιος,Ιουνίου|Ιούλιος,Ιουλίου|Αύγουστος,Αυγούστου|Σεπτέμβριος,Σεπτεμβρίου|Οκτώβριος,Οκτωβρίου|Νοέμβριος,Νοεμβρίου|Δεκέμβριος,Δεκεμβρίου
tr|Turkish|,|ocak|şubat|mart|nisan|mayıs|haziran|temmuz|ağustos|eylül|ekim|kasım|aralık
ru|Russian|,|январь,января|февраль,февраля|март,марта|апрель,апреля|май,мая|июнь,июня|июль,июля|август,августа|сентябрь,сентября|октябрь,октября|ноябрь,ноября|декабрь,декабря
uk|Ukrainian|,|січень,січня|лютий,лютого|березень,березня|квітень,квітня|травень,травня|червень,червня|липень,липня|серпень,серпня|вересень,вересня|жовтень,жовтня|листопад,листопада|грудень,грудня
id|Indonesian|,|Januari|Februari|Maret|April|Mei|Juni|Juli|Agustus|September|Oktober|November|Desember
vi|Vietnamese|,|
`;

const rows = (table) =>
  table
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.split('|'));

const escape = (text) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const field = (name, value) =>
  value === null || value === undefined || value === ''
    ? `    <values>\n        <field>${name}</field>\n        <value xsi:nil="true" />\n    </values>`
    : `    <values>\n        <field>${name}</field>\n        <value xsi:type="xsd:string">${escape(
        value
      )}</value>\n    </values>`;

const record = (type, developerName, label, fields) => {
  const body = [
    '<?xml version="1.0" encoding="UTF-8" ?>',
    '<CustomMetadata',
    '  xmlns="http://soap.sforce.com/2006/04/metadata"',
    '  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
    '  xmlns:xsd="http://www.w3.org/2001/XMLSchema"',
    '>',
    `    <label>${escape(label)}</label>`,
    '    <protected>false</protected>',
    ...fields,
    '</CustomMetadata>',
    ''
  ].join('\n');
  writeFileSync(join(outDir, `${type}.${developerName}.md-meta.xml`), body, 'utf8');
};

mkdirSync(outDir, { recursive: true });

const countries = rows(COUNTRIES);
for (const [code, label, dial, separator] of countries) {
  record('IDP_Country', code, label, [
    field('Dial_Code__c', dial),
    field('Decimal_Separator__c', separator)
  ]);
}

const languages = rows(LANGUAGES);
for (const [code, label, separator, ...months] of languages) {
  const named = months.filter(Boolean);
  if (named.length && named.length !== 12) {
    throw new Error(`${code} lists ${named.length} months, expected 12 or none`);
  }
  record('IDP_Language', code, label, [
    field('Decimal_Separator__c', separator),
    field('Month_Names__c', named.join('|'))
  ]);
}

console.log(
  `Wrote ${countries.length} IDP_Country and ${languages.length} IDP_Language records to ${outDir}`
);
