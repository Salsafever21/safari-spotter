// Reject COCO boxes that clearly belong to a different animal than the folder label.
const ANIMAL = new Set(['bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe']);
const DISTINCT = { elephant: 'elefant', zebra: 'steppenzebra', giraffe: 'giraffe' };
const BIRDS = new Set(['brillenpinguin', 'strauss', 'sekretaer', 'hornrabe', 'gelbschnabeltoko',
  'riesentrappe', 'gaukler', 'schreiseeadler', 'weissrueckengeier', 'gabelracke',
  'helmperlhuhn', 'nilgans', 'hammerkopf', 'sattelstorch', 'marabu', 'flamingo']);

function acceptsPrediction(classKey, prediction) {
  if (!ANIMAL.has(prediction.class) || prediction.score < 0.3) return false;
  if (DISTINCT[prediction.class] && DISTINCT[prediction.class] !== classKey) return false;
  if (BIRDS.has(classKey)) return prediction.class === 'bird';
  if (prediction.class === 'bird') return false;
  if (Object.values(DISTINCT).includes(classKey)) return DISTINCT[prediction.class] === classKey;
  return true;
}

module.exports = { acceptsPrediction };
