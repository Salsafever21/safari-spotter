// Reject COCO boxes that clearly belong to a different animal than the folder label.
const ANIMAL = new Set(['bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe']);
const DISTINCT = { elephant: 'elefant', zebra: 'steppenzebra', giraffe: 'giraffe' };
const BIRDS = new Set(['brillenpinguin', 'strauss', 'sekretaer', 'hornrabe', 'gelbschnabeltoko',
  'riesentrappe', 'gaukler', 'schreiseeadler', 'weissrueckengeier', 'gabelracke',
  'helmperlhuhn', 'nilgans', 'hammerkopf', 'sattelstorch', 'marabu', 'flamingo']);
const FELIDS = new Set(['loewe_m', 'loewin', 'leopard', 'gepard', 'serval', 'karakal']);
const CANIDS = new Set(['tuepfelhyaene', 'wildhund', 'schabrackenschakal', 'loeffelhund']);
const UNGULATES = new Set(['breitmaulnashorn', 'spitzmaulnashorn', 'flusspferd', 'kaffernbueffel',
  'warzenschwein', 'impala', 'streifengnu', 'kudu', 'nyala', 'buschbock', 'elenantilope',
  'wasserbock', 'rappenantilope', 'springbock', 'oryx', 'kuhantilope', 'blessbock',
  'steinboeckchen', 'kronenducker', 'klippspringer']);

function acceptsPrediction(classKey, prediction) {
  if (!ANIMAL.has(prediction.class) || prediction.score < 0.3) return false;
  if (DISTINCT[prediction.class] && DISTINCT[prediction.class] !== classKey) return false;
  if (BIRDS.has(classKey)) return prediction.class === 'bird';
  if (prediction.class === 'bird') return false;
  if (Object.values(DISTINCT).includes(classKey)) return DISTINCT[prediction.class] === classKey;
  if (FELIDS.has(classKey)) return prediction.class === 'cat';
  if (CANIDS.has(classKey)) return prediction.class === 'dog';
  if (UNGULATES.has(classKey)) return ['horse', 'sheep', 'cow'].includes(prediction.class);
  return false; // COCO has no reliable corresponding class: requires a reviewed fallback box.
}

module.exports = { acceptsPrediction };
