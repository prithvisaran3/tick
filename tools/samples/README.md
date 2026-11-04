# Bank alert samples

Tick's parsers read bank alert texts. The regex rules need real examples to tune them. This folder is where you paste those examples.

## What to paste

Paste real alert texts into the matching file. Put one alert on each line.

| Bank | File |
|---|---|
| Chase | `chase.txt` |
| Bank of America | `bank_of_america.txt` |
| Capital One | `capital_one.txt` |
| Amex | `amex.txt` |
| Wells Fargo | `wells_fargo.txt` |
| Citi | `citi.txt` |
| Discover | `discover.txt` |
| Apple Card | `apple_card.txt` |

Each file already exists and contains one comment line. You can leave that line at the top.

If an alert has line breaks, join it into one line.

## Kinds of alerts to include

Try to include a mix of these:

- Purchases
- Refunds
- Deposits
- Pending charges, and the same charge once it has posted
- Tips at restaurants, if the bank shows them
- Foreign currency purchases

More examples help the parsers handle more cases.

## Masking rules

Remove anything private before you paste. Follow these rules:

- **Keep the merchant text exactly as received.** This is the most important part. The parsers depend on it.
- **Last-4 digits:** you can replace them with `0000` if you want. This is optional.
- **Account holder names:** replace them with `XXXX`.
- **Balances:** replace them with `XXXX`.
- **Full card numbers:** never include them. Remove any card number that is not already masked.
- **Login codes:** never include them. This includes one-time passcodes and verification codes.

## What happens next

The tests in `api/tests/` will be extended from these files. Once you paste samples, the parser tests will check the real alert formats.

## Placeholder files

These files are empty except for one comment line. They are ready for you to paste into:

- `tools/samples/chase.txt`
- `tools/samples/bank_of_america.txt`
- `tools/samples/capital_one.txt`
- `tools/samples/amex.txt`
- `tools/samples/wells_fargo.txt`
- `tools/samples/citi.txt`
- `tools/samples/discover.txt`
- `tools/samples/apple_card.txt`
