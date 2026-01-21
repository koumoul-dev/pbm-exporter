import neostandard from 'neostandard'

export default [
  { ignores: ['node_modules/*', 'data/*'] },
  ...neostandard({ ts: true, noJsx: true }),
  {
    rules: {
      'no-undef': 'off' // taken care of by typescript
    }
  }
]
