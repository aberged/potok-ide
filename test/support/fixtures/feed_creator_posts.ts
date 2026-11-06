// Writes `feed_creator_posts.json`: what FeedCreator makes of a set of fields,
// for `test/potok_ide_web/post_templates/post_test.exs` to hold the templates
// here to. Run it again after a change to FeedCreator's templates, from there:
//
//   cd ../potok-feed-creator
//   npx jiti ../potok-ide/test/support/fixtures/feed_creator_posts.ts

import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const { encodePost, hashOf } = await import(resolve('src/post.ts'));
const { TEMPLATES, WAITING_IMAGE } = await import(resolve('src/templates.ts'));

type Case = { template: string; fields: Record<string, string | string[]> };

const long = 'Reč po reč, i tekst koji nikako da stane u jednu karticu deljenog linka. '.repeat(6);

const cases: Case[] = [
  ...TEMPLATES.filter(({ id }) => id !== 'text').map(({ id, sample }) => ({ template: id, fields: sample })),
  {
    template: 'article',
    fields: {
      kicker: "D'Artanjan & <drugovi>",
      title: 'Naslov "pod navodnicima" -- i --> crtice',
      lead: long,
      image: 'HTTPS://example.com/a.png?x=1&y=2',
      caption: 'Foto: **Ana** i *Pera*',
      body: '**jako** i *malo*\n\n[link](https://a.rs) pa https://b.rs/c. Kraj\nnovi red\n\n   \n\n[loš](javascript:alert) <b>tag</b>',
    },
  },
  { template: 'article', fields: { title: 'Samo naslov' } },
  { template: 'article', fields: { title: 'Slika', image: '/avatar/group/12?p=170' } },
  { template: 'article', fields: { title: 'Loša slika', image: 'data:image/png;base64,AAAA' } },
  { template: 'photo', fields: { image: WAITING_IMAGE, title: 'Naslov', about: 'Opis\n\nDrugi pasus' } },
  { template: 'quote', fields: { quote: 'Prvi red\ndrugi [link](https://a.rs) red', author: 'Ana', source: 'Pisma' } },
  { template: 'quote', fields: { quote: 'Samo citat' } },
  {
    template: 'event',
    fields: {
      title: 'Naziv',
      date: '2026-11-14',
      time: '10:00',
      place: 'Most',
      about: 'Opis',
      more: 'a.rs/program?x=1',
    },
  },
  { template: 'event', fields: { title: 'Bez dana', time: '10:00' } },
  { template: 'event', fields: { title: 'Nedelja', date: '2026-11-15' } },
  { template: 'event', fields: { title: 'Nema tog dana', date: '2026-02-30', place: 'Most' } },
  { template: 'event', fields: { title: 'Nije datum', date: '14.11.2026.', more: 'nije link' } },
  ...Array.from({ length: 12 }, (_, month) => ({
    template: 'event',
    fields: { title: 'Mesec', date: `2026-${String(month + 1).padStart(2, '0')}-07` },
  })),
  {
    template: 'list',
    fields: {
      title: 'Naslov',
      intro: 'Uvod',
      items: ['prva', '', '  ', 'druga **jaka**', ...Array.from({ length: 12 }, (_, index) => `još ${index}`)],
    },
  },
  { template: 'list', fields: { title: 'Bez uvoda', items: ['a, b; c', 'd'] } },
  {
    template: 'link',
    fields: { address: 'https://www.Example.com/b', title: 'Naslov', about: 'Opis', image: WAITING_IMAGE },
  },
  { template: 'link', fields: { address: 'example.com', title: 'Bez opisa' } },
  { template: 'link', fields: { address: 'mailto:ana@a.rs', title: 'Pošta' } },
  { template: 'link', fields: { address: 'nije adresa', title: 'Loša adresa' } },
  { template: 'notice', fields: { title: 'Bez nivoa', body: 'Tekst sa [linkom](https://a.rs)' } },
  { template: 'notice', fields: { level: 'info', title: 'Naslov' } },
  { template: 'notice', fields: { level: 'important', title: 'Naslov', body: 'Tekst' } },
  { template: 'notice', fields: { level: 'urgent', title: 'Naslov', body: 'Tekst\n\nDrugi' } },
  { template: 'notice', fields: { level: 'nepoznat', title: 'Naslov' } },
  { template: 'question', fields: { question: 'Zašto?', about: 'Dodatak' } },
];

const posts = cases.map(({ template, fields }) => {
  const { description } = encodePost({ template, fields });
  const html = description.slice(description.indexOf('\n') + 1);

  return { template, fields, description, html, hash: hashOf(html) };
});

const samples = Object.fromEntries(TEMPLATES.map(({ id, sample }) => [id, sample]));
const here = dirname(fileURLToPath(import.meta.url));

writeFileSync(join(here, 'feed_creator_posts.json'), `${JSON.stringify({ posts, samples }, null, 2)}\n`);
