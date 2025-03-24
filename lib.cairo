mod interfaces;
mod utils;
mod car_token;
mod dividend_token;
mod rental_service;

use car_token::CarToken;
use dividend_token::DividendToken;
use rental_service::RentalService;
use interfaces::{IERC721, ICarTokenMetadata, IDividendToken, IRentalService, Listing, Rental, CarData};

#[cfg(test)]
mod tests {
    use super::car_token::tests as car_token_tests;
    use super::dividend_token::tests as dividend_token_tests;
    use super::rental_service::tests as rental_service_tests;
}