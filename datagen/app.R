library(shiny)
library(DT)
library(dplyr)
library(bslib)
library(bsicons)
library(httr)
library(jsonlite)

# Define UI with dark mode switch and theme selector
ui <- page_navbar(
  theme = bs_theme(bootswatch = "flatly"),  # Default theme
  # titlePanel("Synthetic Data Generator with OpenAI",
  #            windowTitle = "SDG with OpenAI"),
  title = tags$span(
    tags$img(
      src = "logo.jpeg",
      width = "46px",
      height = "auto",
      class = "me-3"
      ),
    "Synthetic Data Generator with OpenAI"
  ),
    nav_spacer(), # push nav items to the right
    nav_item(input_dark_mode(id = "dark_mode", mode = "dark")),
  
  sidebar=sidebar(
    textInput("description", "Description (optional)", placeholder = "e.g., Windows event logs"),
    selectizeInput("input_field", "Input Field Name", choices = NULL, multiple = TRUE, options = list(create = TRUE)),
    numericInput("max_tokens", "Max Tokens", value = 10),
    actionButton("generate_data", "Generate Data", icon = icon("equalizer",lib = "glyphicon"), class = "btn-info"),
    actionButton("clear_table", "Clear Fields", icon = icon('broom'), class = "btn-info"),
    actionButton("config", "Enter API Key", icon = icon("link", lib = "glyphicon"),
                 # style = "color: #337ab7; background-color: #f9f9f9; border-color: #f9f9f9;"
                 ),
    
    # theme picker
    selectInput("theme", "Select Theme", choices = c("Flatly", "Minty", "Darkly", "Cyborg", "Journal", "Litera", "Lux", "Materia", "Pulse", "Sandstone", "Simplex", "Sketchy", "Slate", "Solar", "Spacelab", "Superhero", "United", "Yeti")),
    
    # OpenAI model selection
    selectInput("model", "Select Model", choices = c("gpt-4o-mini", "gpt-4o"))
  ),

  verbatimTextOutput("fields_to_gen"),
  card(
    title = "Generated Data",
    status = "info",
    width = 12,
    solidHeader = TRUE,
    collapsible = TRUE,
    collapsed = TRUE,
    dataTableOutput("generated_data")
  ),
    accordion(open = FALSE, 
              accordion_panel(
                title = "Debug Info", icon = bs_icon("bug-fill"),
                verbatimTextOutput("debug_output")
              )
  )
)

server <- function(input, output, session) {
  
  # Change theme and mode reactively -- Cannot specify fg without bg
  observe({
    theme <- input$theme
    bs_theme <- bs_theme(bootswatch = tolower(theme))
    session$setCurrentTheme(bs_theme)
  })
  
  # Reactive variable to store the input fields
  fields <- reactiveVal(data.frame(Field = character(), stringsAsFactors = FALSE))
  
  # Update field list when input_field changes
  observe({
    new_fields <- input$input_field
    if (!is.null(new_fields) && !identical(new_fields, fields()$Field)) {
      fields(data.frame(Field = new_fields, stringsAsFactors = FALSE))
    }
  })
  
  # Fields to generate data - verbatimTextOutput
  output$fields_to_gen <- renderText({
    paste("Fields to generate data:", paste(fields()$Field, collapse = ", "))
  })
  
  # Clear the table
  observeEvent(input$clear_table, {
    fields(data.frame(Field = character(), stringsAsFactors = FALSE))
  })
  
  # Reactive value to store API key
  api_key <- reactiveVal(NULL)
  
  # Show modal when config button is clicked
  observeEvent(input$config, {
    showModal(modalDialog(
      title = "API Key Configuration",
      passwordInput("api_key", "Enter your OpenAI API key:", value = api_key()),
      footer = tagList(
        actionButton("save", "Save", icon = icon("check", lib = "glyphicon"), style = "color: #fff; background-color: #5cb85c; border-color: #4cae4c;"),
        modalButton("Close", icon = icon("remove", lib = "glyphicon"))
      ),
      easyClose = TRUE
    ))
  })
  
  # Save the API key when the save button is clicked
  observeEvent(input$save, {
    if (is.null(input$api_key) || input$api_key == "") {
      showNotification("Please enter an API key before saving.", type = "warning")
    } else {
      api_key(input$api_key)
      removeModal()
      output$debug_output <- renderText({
        paste("API Key:", api_key())
      })
      showNotification("API Key Added", type = "message")
    }
  })
  
  observeEvent(input$generate_data, {
    # Validate API key
    if (is.null(api_key()) || api_key() == "") {
      showNotification("Please enter a valid OpenAI API key", type = "warning")
    } else {
      req(api_key())
      showNotification("Preparing to make API request...", type = "message")
      
      description <- ifelse(is.null(input$description) || input$description == "", 
                            "No specific description provided.", 
                            input$description)
      
      request_body <- list(
        model = input$model, 
        messages = list(
          list(role = "system", content = "You are a data generation tool."),
          list(role = "user", content = paste(
            paste0("Generate ", input$max_tokens, " rows of data."),
            if (!is.null(description) && description != "") {
              paste("--", "Description of the data context:", description)
            } else "",
            "--", "In addition to the data being generated, include data generated for the fields:", paste(fields()$Field, collapse = ", "),
            "Return the data in comma-separated format using the fields as headers. Do not return anything other than the data. Do not include commas within data strings."
          ))
        )
      )
      
      
      print(request_body)
      
      output$debug_output <- renderText({
        paste("Request Body:", toJSON(request_body, auto_unbox = TRUE))
      })
      
      response <- tryCatch({
        POST(
          url = "https://api.openai.com/v1/chat/completions",
          add_headers(Authorization = paste("Bearer", api_key())),
          content_type_json(),
          body = toJSON(request_body, auto_unbox = TRUE)
        )
      }, error = function(e) {
        output$debug_output <- renderText({
          paste("Error in API request:", e$message)
        })
        showNotification("Error in API request. Please check your API key and try again.", type = "error")
        NULL
      })
      
      if (!is.null(response)) {
        response_status <- http_status(response)$category
        response_content <- content(response, "text", encoding = "UTF-8")
        
        output$debug_output <- renderText({
          paste("HTTP status:", response_status, "\nRaw API response:", response_content)
        })
        
        if (response_status == "Success") {
          result <- tryCatch({
            fromJSON(response_content, simplifyVector = FALSE)
          }, error = function(e) {
            output$debug_output <- renderText({
              paste("Error in parsing response:", e$message)
            })
            showNotification("Error parsing response. Please check the format of the response.", type = "error")
            NULL
          })
          
          if (!is.null(result)) {
            if ("choices" %in% names(result) && length(result$choices) > 0) {
              synthetic_data <- result$choices[[1]]$message$content
              
              synthetic_df_parsed <- tryCatch({
                read.csv(text = synthetic_data, header = TRUE, stringsAsFactors = FALSE)
              }, warning = function(w) {
                output$debug_output <- renderText({
                  paste("Warning during CSV parsing:", w$message)
                })
                showNotification("Warning during CSV parsing. Some data may not have been parsed correctly.", type = "warning")
                NULL
              }, error = function(e) {
                output$debug_output <- renderText({
                  paste("Error during CSV parsing:", e$message)
                })
                showNotification("Error parsing response. Please check the format of the response and try again.", type = "error")
                NULL
              })
              
              if (!is.null(synthetic_df_parsed)) {
                output$generated_data <- renderDataTable({
                  datatable(synthetic_df_parsed, extensions = c('Buttons', 'ColReorder'), 
                            options = list(
                              dom = 'Bfrtip',
                              buttons = c('copy', 'csv', 'excel', 'pdf'),
                              colReorder = TRUE,
                              fixedHeader = FALSE,
                              deferRender = TRUE,
                              scrollY = 400,
                              pageLength = 10)
                  )
                })
                
                output$debug_output <- renderText({
                  "API request successful. Data rendered as a DataTable."
                })
                
                showNotification("Synthetic data generated successfully!", type = "message")
              }
            } else {
              output$debug_output <- renderText({
                paste("API request successful but no valid 'choices' field in response. Parsed response:", toString(result))
              })
              showNotification("API response received but no valid data was returned.", type = "warning")
            }
          }
        }
      }
    }
  })
  
  # Function to determine if it's daytime based on local time
  is_daytime <- function() {
    current_time <- as.POSIXlt(Sys.time(), tz = Sys.timezone())
    hour <- current_time$hour
    return(hour >= 12 && hour < 23)  # Adjust the time range based on your preference
  }
  
  # Set initial dark mode based on time of day
  initial_mode <- if (is_daytime()) "light" else "dark"
  toggle_dark_mode(mode = initial_mode, session = session)
  
  # Toggle dark mode based on changes in time
  observe({
    if (is_daytime()) {
      toggle_dark_mode(mode = "light", session = session)
    } else {
      toggle_dark_mode(mode = "dark", session = session)
    }
  })
}

shinyApp(ui, server)


# The app is designed to generate synthetic data using the OpenAI API. The user can specify the fields they want in the data, the number of rows to generate, and a description of the data context. The app then constructs a request body and sends it to the OpenAI API. The API response is parsed and displayed as a data table. 
# The app also includes functionality to save and display an API key, as well as a dark mode toggle. 
# To run the app, you will need to replace the placeholder text in the  api_key  reactive value with your own OpenAI API key. 
# The app is structured as follows: 
# 
# The UI includes a title, a description of the app, a table to specify the fields for the synthetic data, input fields for the number of rows and a description, action buttons to generate data, clear the table, and configure the API key, and buttons to toggle dark and light modes. 
# The server function includes reactive values to store the fields and API key, an observer to show a modal for configuring the API key, an observer to save the API key, an observer to generate synthetic data, and observers to toggle dark and light modes. 
# The app uses the  httr  package to make API requests to the OpenAI API. 
# The app includes error handling for API requests and response parsing. 
# 
# The app is a simple example of how to use the OpenAI API to generate synthetic data in a Shiny app. 
# In this tutorial, we discussed how to use the OpenAI API to generate synthetic data in R. We covered the following topics: 
# 
# An overview of the OpenAI API and the GPT-3 model 
# How to set up an OpenAI account and obtain an API key 
# How to use the OpenAI API to generate synthetic data in R 
# How to create a Shiny app to generate synthetic data using the OpenAI API 
# 
# By following the steps outlined in this tutorial, you should now have a good understanding of how to use the OpenAI API to generate synthetic data in R. 
# The post  How to Use the OpenAI API to Generate Synthetic Data in R appeared first in  The Data School. 
# In this tutorial, we will discuss how to use the  OpenAI API to generate synthetic data in Python. We will cover the following topics: 
# 
# An overview of the OpenAI API and the GPT-3 model 
# How to set up an OpenAI account and obtain an API key
#