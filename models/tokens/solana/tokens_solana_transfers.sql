 {{
  config(
        schema = 'tokens',
        alias = 'transfers',
        materialized = 'incremental',
        file_format = 'delta',
        incremental_strategy = 'merge',
        incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
        unique_key = ['tx_id','outer_instruction_index','inner_instruction_index', 'block_slot'],
        post_hook='{{ expose_spells(\'["solana"]\',
                                    "sector",
                                    "tokens",
                                    \'["ilemi"]\') }}')
}}

SELECT
    call_block_time as block_time
    , call_block_slot as block_slot
    , action
    , amount
    , COALESCE(tk_s.token_mint_address, tk_d.token_mint_address) as token_mint_address
    , tk_s.token_balance_owner as from_owner
    , tk_d.token_balance_owner as to_owner
    , account_source as from_token_account
    , account_destination as to_token_account
    , call_tx_signer as tx_signer
    , call_tx_id as tx_id
    , call_outer_instruction_index as outer_instruction_index
    , COALESCE(call_inner_instruction_index,0) as inner_instruction_index
    , call_outer_executing_account as outer_executing_account
FROM (  
      SELECT account_source, account_destination, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'transfer' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_transfer') }}

      UNION ALL

      SELECT account_source, account_destination, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'transfer' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_transferChecked') }}

      UNION ALL

      SELECT null, account_account as account_destination, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'mint' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_mintTo') }}

      UNION ALL

      SELECT null, account_account as account_destination, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'mint' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_mintToChecked') }}

      UNION ALL

      SELECT account_account as account_source, null, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'burn' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_burn') }}

      UNION ALL

      SELECT account_account as account_source, null, amount, call_tx_id, call_block_time, call_block_slot, call_outer_executing_account, call_tx_signer, 'burn' as action, call_outer_instruction_index, call_inner_instruction_index
      FROM {{ source('spl_token_solana','spl_token_call_burnChecked') }}
) tr
--get token and accounts
LEFT JOIN {{ ref('solana_utils_token_accounts') }} tk_s ON tk_s.address = tr.account_source 
LEFT JOIN {{ ref('solana_utils_token_accounts') }} tk_d ON tk_d.address = tr.account_destination
WHERE 1=1
{% if is_incremental() %}
AND {{incremental_predicate('call_block_time')}}
{% endif %}
-- WHERE call_block_time > now() - interval '30' day

UNION ALL 

--for the reader, note that SOL is special and can be transferred without calling the transfer instruction. It is also minted and burned without instructions. So to get balances, use daily_balances or account_activity instead of transfers.
SELECT
    call_block_time as block_time
    , call_block_slot as block_slot
    , 'transfer' as action
    , lamports as amount --1e9
    , 'native' as token_mint_address
    , account_from as from_owner
    , account_to as to_owner
    , account_from as from_token_account
    , account_to as to_token_account
    , call_tx_signer as tx_signer
    , call_tx_id as tx_id
    , call_outer_instruction_index as outer_instruction_index
    , COALESCE(call_inner_instruction_index,0) as inner_instruction_index
    , call_outer_executing_account as outer_executing_account
FROM (
      SELECT account_from, account_to, lamports, call_tx_signer, call_block_time, call_block_slot, call_tx_id, call_outer_instruction_index, call_inner_instruction_index, call_outer_executing_account
      FROM {{ source('system_program_solana','system_program_call_Transfer') }}
      WHERE 1=1
      {% if is_incremental() %}
      AND {{incremental_predicate('call_block_time')}}
      {% endif %}

      UNION ALL 
      
      SELECT account_funding_account, account_recipient_account, lamports, call_tx_signer, call_block_time, call_block_slot, call_tx_id, call_outer_instruction_index, call_inner_instruction_index, call_outer_executing_account
      FROM {{ source('system_program_solana','system_program_call_TransferWithSeed') }}
      WHERE 1=1
      {% if is_incremental() %}
      AND {{incremental_predicate('call_block_time')}}
      {% endif %}
)
-- WHERE call_block_time > now() - interval '30' day