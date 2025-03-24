use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct CarData {
    pub vin: u256,
    pub plate_number: u256,
    pub body_type: u256,
    pub brand: u256,
    pub model: u256,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Listing {
    pub owner: ContractAddress,
    pub daily_price: u256,
    pub deposit: u256,
    pub is_listed: bool
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Rental {
    pub renter: ContractAddress,
    pub start_time: u64,
    pub end_time: u64,
    pub paid_amount: u256
}

#[starknet::interface]
trait IERC721<TContractState> {
    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
    fn transfer_from(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256
    );
}

#[starknet::interface]
trait ICarTokenMetadata<TContractState> {
    fn get_car_data(self: @TContractState, token_id: u256) -> CarData;
    fn mint_car(
        ref self: TContractState,
        token_id: u256,
        vin: u256,
        plate_number: u256,
        body_type: u256,
        brand: u256,
        model: u256,
    );
}

#[starknet::interface]
trait IDividendToken<TContractState> {
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn withdraw_dividends(ref self: TContractState, amount: u256);
    fn balance_of(self: @TContractState, user: ContractAddress) -> u256;
    fn total_supply(self: @TContractState) -> u256;
    fn decimals(self: @TContractState) -> u8;
    fn symbol(self: @TContractState) -> felt252;
    fn name(self: @TContractState) -> felt252;
}

#[starknet::interface]
trait IRentalService<TContractState> {
    fn list_car(
        ref self: TContractState,
        token_id: u256,
        daily_price: u256,
        deposit: u256
    );
    fn unlist_car(ref self: TContractState, token_id: u256);
    fn rent_car(ref self: TContractState, token_id: u256, duration_days: u64);
    fn return_car(ref self: TContractState, token_id: u256);
    fn get_listing(self: @TContractState, token_id: u256) -> Listing;
    fn get_rental(self: @TContractState, token_id: u256) -> Rental;
    fn is_car_rented(self: @TContractState, token_id: u256) -> bool;
    fn set_deposit_forfeit(ref self: TContractState, token_id: u256, forfeit_percentage: u8);
}