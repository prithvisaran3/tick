# iOS Shortcuts setup for Tick

This guide sets up two Personal Automations on your iPhone. They send purchases to Tick, so they show up in the app without you typing them in.

- **Automation A** reads bank alert texts.
- **Automation B** reads Apple Pay transactions.

You will need the Shortcuts app, and a capture token from the Tick app.

## What you need

- **Ingest URL:** `https://tick-api-production.up.railway.app/ingest`
- **Method:** POST
- **Request body type:** JSON
- **Headers:**
  - `X-Tick-Token`: your capture token
  - `Content-Type`: `application/json` (always add this one too)

## Get your capture token

1. Open the Tick app.
2. Go to **Settings > Capture token**.
3. Tap **Make new token**.
4. Copy the token. It starts with `tk_`.

Tick shows the token only once. If you lose it, make a new one. Making a new token turns the old one off, so any automation using the old token will stop working until you update it.

## Automation A: Bank alert texts

### Create the automation

1. Open the **Shortcuts** app.
2. Tap the **Automation** tab.
3. Tap **+**, then choose **Message**.
4. Under **Sender**, choose your bank's alert number.

Use this list as a starting point:

| Bank | Alert number |
|---|---|
| Chase | 24273 |
| Bank of America | 692632 |
| Capital One | 227898 |
| Amex | 25270 |
| Wells Fargo | 93557 |
| Citi | 692484 |
| Discover | 347268 |

Bank alert numbers can change. Check the sender name shown in your Messages app for a recent bank alert, and use that.

5. Under **Message Contains**, you can add a filter like `transaction` or `charged`. This is optional. It stops the automation from running on every text from the bank.
6. Tap **Next**.
7. Choose **Run Immediately**. Do not choose **Run After Confirmation**.
8. Turn off **Notify When Run**.
9. Tap **Next**.

### Add the actions

1. Tap **Add Action** and search for **Get Contents of URL**.
2. In the **URL** field, paste:
   `https://tick-api-production.up.railway.app/ingest`
3. Tap **Show More**.
4. Set **Method** to **POST**.
5. Tap **Headers**, then add two headers:
   - Key: `X-Tick-Token`. Value: paste your capture token.
   - Key: `Content-Type`. Value: `application/json`.
6. Set **Request Body** to **JSON**.
7. Add two fields:
   - `source` (Text): type `sms`
   - `text` (Text): tap the field, then choose the magic variable **Message** from the automation trigger.
8. Tap **Done**.

The body should look like this:

```json
{
  "source": "sms",
  "text": "[Message]"
}
```

Here `[Message]` stands for the Message variable from the trigger. It is not typed text.

## Automation B: Apple Pay transactions

### Create the automation

1. In the **Automation** tab, tap **+**, then choose **Transaction**.
2. Choose the cards you want to track. You can pick more than one.
3. Tap **Next**.
4. Choose **Run Immediately**.
5. Tap **Next**.

### Add the actions

1. Tap **Add Action** and search for **Get Contents of URL**.
2. Set the **URL**, **Method**, and **Headers** the same way as Automation A.
3. Set **Request Body** to **JSON**.
4. Add four fields:
   - `source` (Text): type `applepay`
   - `merchant` (Text): choose the magic variable **Merchant**
   - `amount` (Text): choose the magic variable **Amount**
   - `card` (Text): choose the magic variable **Card** (or **Card Name**, depending on what your iPhone shows)
5. Tap **Done**.

### Apple Card

Apple Card isn't on Plaid. Tick gets Apple Card purchases in two ways:

1. **Live, from this automation.** In step 2 of "Create the automation", make sure **Apple Card** is one of the selected cards.
   The `card` field must be the **Card** magic variable. Tick reads the card name: anything named "Apple Card" goes to an
   **Apple Card** account in Tick (it's created the first time). Other card names are matched to a linked card when only
   one card fits, for example "Discover It Card" goes to Discover ••1234.
2. **From the monthly statement.** In Wallet, open **Apple Card**, tap **Statements**, pick a month, then tap
   **Export Transactions** and choose **CSV**. Save it to Files. In Tick, open **Settings > Import Apple Card statement**
   and choose the file.

   Tick then tells you "Imported N, skipped M duplicates". A row is skipped when Tick already has a purchase with the same
   amount, a similar merchant and a date within two days, usually because Wallet caught it live. Importing the same file
   again adds nothing. Payments to Apple Card count as transfers, not spending, so the card's purchases aren't counted twice.

Test it: send this body from the test Shortcut below. The purchase should land on the Apple Card account.

```json
{"source": "applepay", "merchant": "Test Coffee", "amount": "1.00", "card": "Apple Card"}
```

## Test each automation

Testing first saves you from waiting for a real purchase.

### Test with a Shortcut

1. In the **Shortcuts** app, tap **+** to make a new Shortcut.
2. Add **Get Contents of URL** with the same URL, method, and headers as above.
3. Set the body to JSON with hardcoded values. For example:

```json
{
  "source": "sms",
  "text": "Test alert: $1.00 charged at Test Coffee"
}
```

4. Tap the play button to run it.

A good response looks like this:

```json
{"ok":true,"status":"received"}
```

The response is the same whatever happened, so a leaked token can't be used to learn what is in your ledger.

### Check Tick

- If the transaction is clear, it appears in **Today**.
- If Tick is less than 80% sure about the transaction, it appears in **Caught** instead. Check it there and confirm or fix it.

## Troubleshooting

| What you see | What it means | What to do |
|---|---|---|
| 401 | The token is wrong or has been turned off. | Copy the current token from Settings > Capture token. If you made a new one, update the header. |
| 429 | Requests are coming in too fast. | Wait a minute and try again. |
| 422 | A required field is missing. | Check that `source` and `text` (or `merchant` and `amount`) are in the body. |
| Nothing happens | The automation is set to **Ask Before Running**. | Open the automation and choose **Run Immediately**. Turn off **Ask Before Running** if it is on. |

If you see another error, check the URL for typos and run the test Shortcut again.

## Privacy

- Bank texts and Apple Pay details leave your phone only to Tick's own API.
- Tick stores the raw payloads in `ingest_logs`. This helps with fixing parsing problems.
- Keep your capture token private. Anyone with it can send data to your Tick account.

## Duplicates are merged

The same purchase can arrive more than once. For example, it may come by bank text, by Apple Pay, and through the bank link. Tick merges these into one transaction, so you should not see the same purchase three times.
